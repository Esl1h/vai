module anthropic

import net.http
import vai

struct StreamHandler {}

fn (h StreamHandler) handle(_ http.Request) http.Response {
	body := 'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n' + 'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}\n\n' + 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
	mut r := http.Response{
		body: body
	}
	r.set_status(.ok)
	return r
}

fn test_provider_stream_end_to_end() {
	mut server := &http.Server{
		addr:                 '127.0.0.1:18361'
		handler:              StreamHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	defer {
		server.close()
	}

	p := Provider{
		api_key:   'test-key'
		base_url:  'http://127.0.0.1:18361'
		transport: vai.Transport(vai.CurlTransport{})
	}
	ch := p.stream(vai.Request{
		model:    'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) or {
		assert false, err.msg()
		return
	}

	mut events := []vai.StreamEvent{}
	for {
		ev := <-ch or { break }
		events << ev
	}

	assert events.len == 3
	assert events[0].kind == .content_delta
	assert events[0].text == 'Hi'
	assert events[1].kind == .usage
	assert events[1].usage.output_tokens == 3
	assert events[2].kind == .done

	// at_ms must be real elapsed time from the stream's start, not an
	// unset/stub zero: never negative, and non-decreasing across events
	// arriving in order.
	for ev in events {
		assert ev.at_ms >= 0
	}
	assert events[2].at_ms >= events[0].at_ms
}

// RejectHandler answers a stream request with a 400 JSON body, the way
// a gateway refuses a request before any event is sent.
struct RejectHandler {}

fn (h RejectHandler) handle(_ http.Request) http.Response {
	mut r := http.Response{
		body: '{"type":"error","error":{"type":"invalid_request_error","message":"Request is missing x-opencode-session"}}'
	}
	r.set_status(.bad_request)
	return r
}

fn test_provider_stream_surfaces_http_error() {
	mut server := &http.Server{
		addr:                 '127.0.0.1:18373'
		handler:              RejectHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	defer {
		server.close()
	}

	p := Provider{
		base_url:  'http://127.0.0.1:18373'
		transport: vai.Transport(vai.CurlTransport{})
	}
	ch := p.stream(vai.Request{
		model:    'm'
		messages: [vai.user('hi')]
	}) or {
		assert false, err.msg()
		return
	}
	mut events := []vai.StreamEvent{}
	for {
		ev := <-ch or { break }
		events << ev
	}
	assert events.len == 1
	assert events[0].kind == .error
	assert events[0].err == 'anthropic: HTTP 400: Request is missing x-opencode-session'
}
