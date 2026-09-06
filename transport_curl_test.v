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

fn start_sse_server(addr string) &http.Server {
	mut server := &http.Server{
		addr: addr
		handler: SseHandler{}
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
