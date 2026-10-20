module vai

import os
import time

// CurlTransport shells out to curl for both request kinds, and is what
// covers streaming: V's own net.http has no streaming response support
// (see NativeTransport), so this is the only way vai can honor
// Request.stream. curl is assumed to be on the host, which is true of
// virtually every Linux machine already.
pub struct CurlTransport {
pub:
	connect_timeout_secs int = 10
	// max_time_secs bounds post_json's whole request. Not applied to
	// post_stream: a single fixed ceiling would kill a legitimately
	// long, healthy generation. stall_timeout_secs guards that path
	// instead, so a slow-but-progressing stream isn't punished for
	// taking a while, only one that's actually stopped.
	max_time_secs int = 120
	// stall_timeout_secs aborts post_stream if curl sees effectively
	// zero throughput for this many consecutive seconds (curl's
	// --speed-limit/--speed-time), regardless of total elapsed time.
	stall_timeout_secs int = 30
}

fn curl_args(url string, headers map[string]string, connect_timeout_secs int) []string {
	mut args := ['-sS', '-N', '-X', 'POST', '--connect-timeout', '${connect_timeout_secs}']
	for k, v in headers {
		args << '-H'
		args << '${k}: ${v}'
	}
	// The body goes through curl's stdin (`@-`), not argv: Linux caps a
	// single argument at 128 KB, and a long prompt (a whole file, a
	// journal window) blew past it with the misleading error "curl
	// produced no output" because execve itself failed.
	args << '--data-binary'
	args << '@-'
	args << url
	return args
}

// feed_body writes the request body to curl's stdin and closes it, so
// curl sees EOF and sends the request. os.Process has no stdin_close;
// closing the pipe's write end by hand and marking it -1 keeps
// Process.close() from closing it twice.
fn feed_body(mut p os.Process, body string) {
	p.stdin_write(body)
	os.fd_close(p.stdio_fd[0])
	p.stdio_fd[0] = -1
}

// post_json runs curl to completion and returns the full response. The
// status code rides along after a newline curl itself appends
// (`-w '\n%{http_code}'`), so this needs no separate header-dump file.
pub fn (t CurlTransport) post_json(url string, headers map[string]string, body string) !HttpResponse {
	mut args := curl_args(url, headers, t.connect_timeout_secs)
	args << '--max-time'
	args << '${t.max_time_secs}'
	args << '-w'
	args << '\n%{http_code}'

	mut p := os.new_process('curl')
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	feed_body(mut p, body)
	out := p.stdout_slurp()
	err_out := p.stderr_slurp()
	p.wait()
	p.close()

	idx := out.last_index('\n') or { return error('curl produced no output') }
	status := out[idx + 1..].trim_space().int()
	// curl still writes the -w format string on total connection failure
	// (timeout, refused, DNS), just with %{http_code} as "000", that is
	// not a valid HttpResponse to hand back as if a server had answered,
	// it is the transport itself failing, which the caller needs as an
	// error to retry on, not a status code to inspect.
	if status == 0 {
		return error('curl could not complete the request: ${err_out.trim_space()}')
	}
	return HttpResponse{
		status: status
		body:   out[..idx]
	}
}

// post_stream runs curl in the background and turns its stdout into
// RawSseEvent values on the returned channel, closing it once curl exits
// and every buffered byte has been consumed. os.Process has no
// line-buffered read in this V version, only stdout_read() (whatever
// bytes are currently available) and stdout_slurp() (blocks for
// everything), so the line splitting and partial-line buffering across
// reads happens here, not in the stdlib.
pub fn (t CurlTransport) post_stream(url string, headers map[string]string, body string) !chan RawSseEvent {
	mut args := curl_args(url, headers, t.connect_timeout_secs)
	args << '--speed-limit'
	args << '1'
	args << '--speed-time'
	args << '${t.stall_timeout_secs}'
	// The status only exists once curl is done, so it goes to stderr,
	// apart from the event stream, for pump_curl_stdout to read at exit.
	args << '-w'
	args << '%{stderr}\n${curl_status_marker}%{http_code}\n'
	mut p := os.new_process('curl')
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	feed_body(mut p, body)

	ch := chan RawSseEvent{cap: 32}
	spawn pump_curl_stdout(mut p, ch)
	return ch
}

const curl_status_marker = 'vai-http-status:'

// max_error_body caps how much of a non-SSE answer is kept for the error
// event: enough for any JSON error body, bounded for a server that
// answers with something huge.
const max_error_body = 65536

fn pump_curl_stdout(mut p os.Process, ch chan RawSseEvent) {
	mut parser := SseParser{}
	mut buf := ''
	// Lines seen before the first event: an error answer is a plain JSON
	// body, not an event stream, so this is the only place it survives.
	mut preamble := []string{}
	mut preamble_len := 0
	mut sent := 0
	for {
		// Liveness is sampled before the read on purpose: if curl writes
		// its last bytes and exits between the two calls, the read still
		// drains them and the loop comes round once more. Sampling it
		// after an empty read would drop exactly that tail.
		alive := p.is_alive()
		chunk := p.stdout_read()
		if chunk != '' {
			buf += chunk
			for {
				nl_pos := buf.index('\n') or { break }
				line := buf[..nl_pos].trim_string_right('\r')
				buf = buf[nl_pos + 1..]
				if sent == 0 && preamble_len < max_error_body {
					preamble << line
					preamble_len += line.len + 1
				}
				if ev := parser.feed(line) {
					ch <- ev
					sent++
				}
			}
			continue
		}
		if !alive {
			break
		}
		time.sleep(10 * time.millisecond)
	}

	// A line with no trailing newline, and the blank line that ends the
	// last event, can both be missing if the connection just closed ,
	// flush whatever is left through the parser so nothing is dropped.
	if buf != '' {
		tail := buf.trim_string_right('\r')
		if sent == 0 && preamble_len < max_error_body {
			preamble << tail
		}
		if ev := parser.feed(tail) {
			ch <- ev
			sent++
		}
	}
	if ev := parser.feed('') {
		ch <- ev
		sent++
	}

	err_out := p.stderr_slurp()
	p.wait()
	exit_code := p.code
	p.close()
	if ev := curl_outcome(err_out, exit_code, preamble.join('\n'), sent) {
		ch <- ev
	}
	ch.close()
}

// curl_outcome turns how curl ended into the synthetic last event, or
// none for a 2xx stream that curl finished cleanly. The body is only
// attached when no event got through: an error answer is a plain JSON
// body, so lines read after a real event can't be one.
fn curl_outcome(stderr string, exit_code int, preamble string, sent int) ?RawSseEvent {
	mut status := 0
	mut messages := []string{}
	for line in stderr.split_into_lines() {
		if line.starts_with(curl_status_marker) {
			status = line.all_after(curl_status_marker).trim_space().int()
		} else if line.trim_space() != '' {
			messages << line.trim_space()
		}
	}
	if status >= 300 {
		return RawSseEvent{
			status: status
			data:   if sent == 0 { preamble.trim_space() } else { '' }
		}
	}
	if exit_code != 0 || status == 0 {
		detail := if messages.len > 0 {
			messages.join('; ')
		} else {
			'curl exited with code ${exit_code}'
		}
		return RawSseEvent{
			err: detail
		}
	}
	return none
}
