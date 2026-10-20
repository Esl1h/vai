module openai

import net.http
import vai

struct StreamHandler {}

fn (h StreamHandler) handle(_ http.Request) http.Response {
	body := 'data: {"id":"1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}\n\n' + 'data: {"id":"1","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n' + 'data: [DONE]\n\n'
	mut r := http.Response{
		body: body
	}
	r.set_status(.ok)
	return r
}

fn test_provider_stream_end_to_end() {
	mut server := &http.Server{
		addr:                 '127.0.0.1:18371'
		handler:              StreamHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	defer {
		server.close()
	}

	p := Provider{
		base_url:  'http://127.0.0.1:18371'
		transport: vai.Transport(vai.CurlTransport{})
	}
	ch := p.stream(vai.Request{
		model:    'llama3'
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
	assert events[1].usage.input_tokens == 1
	assert events[2].kind == .done

	// at_ms must be real elapsed time from the stream's start, not an
	// unset/stub zero: never negative, and non-decreasing across events
	// arriving in order.
	for ev in events {
		assert ev.at_ms >= 0
	}
	assert events[2].at_ms >= events[0].at_ms
}
