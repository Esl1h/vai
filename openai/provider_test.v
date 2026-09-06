module openai

import net.http
import time
import vai

struct MockHandler {
mut:
	call_count  int
	fail_times  int
	fail_status int
}

fn (mut h MockHandler) handle(_ http.Request) http.Response {
	h.call_count++
	if h.call_count <= h.fail_times {
		mut r := http.Response{
			body: '{"error":{"type":"rate_limit_error","message":"slow down"}}'
		}
		r.set_status(unsafe { http.Status(h.fail_status) })
		return r
	}
	mut r := http.Response{
		body: '{"id":"chatcmpl-1","model":"llama3","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
	}
	r.set_status(.ok)
	return r
}

fn start_mock(addr string, fail_times int, fail_status int) &http.Server {
	mut server := &http.Server{
		addr: addr
		handler: MockHandler{
			fail_times: fail_times
			fail_status: fail_status
		}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	return server
}

fn test_provider_complete_success() {
	mut server := start_mock('127.0.0.1:18341', 0, 0)
	defer {
		server.close()
	}

	p := Provider{
		base_url: 'http://127.0.0.1:18341'
	}
	resp := p.complete(vai.Request{
		model: 'llama3'
		messages: [vai.user('hi')]
	}) or {
		assert false, err.msg()
		return
	}
	assert resp.id == 'chatcmpl-1'
	assert resp.usage.input_tokens == 1
}

fn test_provider_complete_retries_then_succeeds() {
	mut server := start_mock('127.0.0.1:18342', 2, 429)
	defer {
		server.close()
	}

	p := Provider{
		base_url: 'http://127.0.0.1:18342'
		retry: vai.RetryPolicy{
			max_attempts: 5
			base_delay: 5 * time.millisecond
			max_delay: 20 * time.millisecond
		}
	}
	resp := p.complete(vai.Request{
		model: 'llama3'
		messages: [vai.user('hi')]
	}) or {
		assert false, err.msg()
		return
	}
	assert resp.id == 'chatcmpl-1'
}

fn test_provider_complete_does_not_retry_non_retryable_status() {
	mut server := start_mock('127.0.0.1:18343', 99, 400)
	defer {
		server.close()
	}

	p := Provider{
		base_url: 'http://127.0.0.1:18343'
	}
	if _ := p.complete(vai.Request{
		model: 'llama3'
		messages: [vai.user('hi')]
	}) {
		assert false, 'expected an error'
	}
}
