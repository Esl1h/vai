module vai

import net.http

// SseHandler returns a canned three-event SSE body. Like every other test
// server in this repo, it never leaves the machine.
struct SseHandler {}

fn (h SseHandler) handle(_ http.Request) http.Response {
	body := 'event: message_start\ndata: {"type":"message_start"}\n\n' + 'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n' + 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
	mut r := http.Response{
		body: body
	}
	r.set_status(.ok)
	return r
}

// BodyLenHandler answers with the request body's length, to prove a body
// of any size reaches the server intact.
struct BodyLenHandler {}

fn (h BodyLenHandler) handle(req http.Request) http.Response {
	mut r := http.Response{
		body: '{"len":${req.data.len}}'
	}
	r.set_status(.ok)
	return r
}

fn start_sse_server(addr string) &http.Server {
	mut server := &http.Server{
		addr:                 addr
		handler:              SseHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	return server
}

fn test_curl_transport_post_json() {
	mut server := start_sse_server('127.0.0.1:18351')
	defer {
		server.close()
	}

	t := CurlTransport{}
	resp := t.post_json('http://127.0.0.1:18351/', {}, '{}') or {
		assert false, err.msg()
		return
	}
	assert resp.status == 200
	assert resp.body.contains('message_start')
}

fn test_curl_transport_post_json_body_larger_than_one_argv() {
	// Linux caps one argv string at 128 KB; the body has to go through
	// curl's stdin for anything bigger (a whole file, a journal window).
	mut server := &http.Server{
		addr:                 '127.0.0.1:18353'
		handler:              BodyLenHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	defer {
		server.close()
	}

	body := '{"x":"' + 'a'.repeat(200_000) + '"}'
	t := CurlTransport{}
	resp := t.post_json('http://127.0.0.1:18353/', {}, body) or {
		assert false, err.msg()
		return
	}
	assert resp.status == 200
	assert resp.body == '{"len":${body.len}}', resp.body
}

fn test_curl_transport_post_stream() {
	mut server := start_sse_server('127.0.0.1:18352')
	defer {
		server.close()
	}

	t := CurlTransport{}
	ch := t.post_stream('http://127.0.0.1:18352/', {}, '{}') or {
		assert false, err.msg()
		return
	}

	mut events := []RawSseEvent{}
	for {
		ev := <-ch or { break }
		events << ev
	}

	assert events.len == 3
	assert events[0].event == 'message_start'
	assert events[1].event == 'content_block_delta'
	assert events[1].data.contains('"text":"Hi"')
	assert events[2].event == 'message_stop'
}

// RateLimitHandler answers like a provider refusing a stream: a plain
// JSON error body with a 429, not an event stream.
struct RateLimitHandler {}

fn (h RateLimitHandler) handle(_ http.Request) http.Response {
	mut r := http.Response{
		body: '{"error":{"type":"rate_limit_error","message":"slow down"}}'
	}
	r.set_status(.too_many_requests)
	return r
}

fn collect(ch chan RawSseEvent) []RawSseEvent {
	mut events := []RawSseEvent{}
	for {
		ev := <-ch or { break }
		events << ev
	}
	return events
}

fn test_curl_transport_post_stream_reports_http_error() {
	mut server := &http.Server{
		addr:                 '127.0.0.1:18354'
		handler:              RateLimitHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	defer {
		server.close()
	}

	ch := CurlTransport{}.post_stream('http://127.0.0.1:18354/', {}, '{}') or {
		assert false, err.msg()
		return
	}
	events := collect(ch)
	assert events.len == 1
	assert events[0].status == 429
	assert events[0].data.contains('slow down')
	assert events[0].err == ''
}

fn test_curl_transport_post_stream_reports_connection_failure() {
	// Nothing listens on this port.
	ch := CurlTransport{
		connect_timeout_secs: 2
	}.post_stream('http://127.0.0.1:18355/', {}, '{}') or {
		assert false, err.msg()
		return
	}
	events := collect(ch)
	assert events.len == 1
	assert events[0].status == 0
	assert events[0].err != ''
}

fn test_curl_outcome() {
	ok := '\n${curl_status_marker}200\n'
	if _ := curl_outcome(ok, 0, '', 3) {
		assert false, 'a clean 2xx stream needs no extra event'
	}
	// A stall after the stream started: status 200, curl exit 28.
	stalled := curl_outcome('curl: (28) Operation too slow\n${curl_status_marker}200\n', 28,
		'', 3) or {
		assert false, 'expected an error event'
		return
	}
	assert stalled.err.contains('too slow')
	// A non-2xx answer whose body came as events keeps no stale body.
	late := curl_outcome('\n${curl_status_marker}500\n', 0, 'data: x', 1) or {
		assert false, 'expected a status event'
		return
	}
	assert late.status == 500
	assert late.data == ''
}
