module anthropic

import net.http
import time
import vai

// MockHandler never leaves the machine, per this project's rule against
// hitting real endpoints in tests. It fails with a given status for the
// first fail_times calls, then returns a canned success body, so a test
// can exercise the retry path deterministically.
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
			body: '{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}'
		}
		r.set_status(unsafe { http.Status(h.fail_status) })
		return r
	}
	mut r := http.Response{
		body: '{"id":"msg_1","model":"claude-sonnet-5","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
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
	mut server := start_mock('127.0.0.1:18331', 0, 0)
	defer {
		server.close()
	}

	p := Provider{
		api_key: 'test-key'
		base_url: 'http://127.0.0.1:18331'
	}
	resp := p.complete(vai.Request{
		model: 'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) or {
		assert false, err.msg()
		return
	}
	assert resp.id == 'msg_1'
	assert resp.usage.input_tokens == 1
}

fn test_provider_complete_retries_then_succeeds() {
	mut server := start_mock('127.0.0.1:18332', 2, 429)
	defer {
		server.close()
	}

	p := Provider{
		api_key: 'test-key'
		base_url: 'http://127.0.0.1:18332'
		retry: vai.RetryPolicy{
			max_attempts: 5
			base_delay: 5 * time.millisecond
			max_delay: 20 * time.millisecond
		}
	}
	resp := p.complete(vai.Request{
		model: 'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) or {
		assert false, err.msg()
		return
	}
	assert resp.id == 'msg_1'
}

fn test_provider_complete_does_not_retry_non_retryable_status() {
	mut server := start_mock('127.0.0.1:18333', 99, 400)
	defer {
		server.close()
	}

	p := Provider{
		api_key: 'test-key'
		base_url: 'http://127.0.0.1:18333'
	}
	if _ := p.complete(vai.Request{
		model: 'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) {
		assert false, 'expected an error'
	}
}

fn test_provider_complete_gives_up_after_max_attempts() {
	mut server := start_mock('127.0.0.1:18334', 99, 429)
	defer {
		server.close()
	}

	p := Provider{
		api_key: 'test-key'
		base_url: 'http://127.0.0.1:18334'
		retry: vai.RetryPolicy{
			max_attempts: 2
			base_delay: 5 * time.millisecond
			max_delay: 10 * time.millisecond
		}
	}
	if _ := p.complete(vai.Request{
		model: 'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) {
		assert false, 'expected an error'
	}
}
