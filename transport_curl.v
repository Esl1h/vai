module vai

import os
import time

// CurlTransport shells out to curl for both request kinds, and is what
// covers streaming: V's own net.http has no streaming response support
// (see NativeTransport), so this is the only way vai can honor
// Request.stream. curl is assumed to be on the host, which is true of
// virtually every Linux machine already.
pub struct CurlTransport {}

fn curl_args(url string, headers map[string]string, body string) []string {
	mut args := ['-sS', '-N', '-X', 'POST']
	for k, v in headers {
		args << '-H'
		args << '${k}: ${v}'
	}
	args << '-d'
	args << body
	args << url
	return args
}

// post_json runs curl to completion and returns the full response. The
// status code rides along after a newline curl itself appends
// (`-w '\n%{http_code}'`), so this needs no separate header-dump file.
pub fn (t CurlTransport) post_json(url string, headers map[string]string, body string) !HttpResponse {
	mut args := curl_args(url, headers, body)
	args << '-w'
	args << '\n%{http_code}'

	mut p := os.new_process('curl')
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	out := p.stdout_slurp()
	p.wait()
	p.close()

	idx := out.last_index('\n') or { return error('curl produced no output') }
	status := out[idx + 1..].trim_space().int()
	return HttpResponse{
		status: status
		body: out[..idx]
	}
}

// post_stream runs curl in the background and turns its stdout into
// RawSseEvent values on the returned channel, closing it once curl exits
// and every buffered byte has been consumed. os.Process has no
// line-buffered read in this V version, only stdout_read() (whatever
// bytes are currently available) and stdout_slurp() (blocks for
// everything) — so the line splitting and partial-line buffering across
// reads happens here, not in the stdlib.
pub fn (t CurlTransport) post_stream(url string, headers map[string]string, body string) !chan RawSseEvent {
	args := curl_args(url, headers, body)
	mut p := os.new_process('curl')
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()

	ch := chan RawSseEvent{ cap: 32 }
	spawn pump_curl_stdout(mut p, ch)
	return ch
}

fn pump_curl_stdout(mut p os.Process, ch chan RawSseEvent) {
	mut parser := SseParser{}
	mut buf := ''
	for {
		chunk := p.stdout_read()
		if chunk != '' {
			buf += chunk
			for {
				nl_pos := buf.index('\n') or { break }
				line := buf[..nl_pos].trim_string_right('\r')
				buf = buf[nl_pos + 1..]
				if ev := parser.feed(line) {
					ch <- ev
				}
			}
			continue
		}
		if !p.is_alive() {
			break
		}
		time.sleep(10 * time.millisecond)
	}

	// A line with no trailing newline, and the blank line that ends the
	// last event, can both be missing if the connection just closed —
	// flush whatever is left through the parser so nothing is dropped.
	if buf != '' {
		if ev := parser.feed(buf.trim_string_right('\r')) {
			ch <- ev
		}
	}
	if ev := parser.feed('') {
		ch <- ev
	}

	p.wait()
	p.close()
	ch.close()
}
