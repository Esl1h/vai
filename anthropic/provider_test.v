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

// SlowHandler always succeeds, after a delay large enough that
// latency_ms being real timing (not a stub returning a constant) is
// unambiguous even under scheduling jitter.
struct SlowHandler {}

fn (h SlowHandler) handle(_ http.Request) http.Response {
	time.sleep(50 * time.millisecond)
	mut r := http.Response{
		body: '{"id":"msg_1","model":"claude-sonnet-5","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
	}
	r.set_status(.ok)
	return r
}

fn start_mock(addr string, fail_times int, fail_status int) &http.Server {
	mut server := &http.Server{
		addr:                 addr
		handler:              MockHandler{
			fail_times:  fail_times
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
		api_key:  'test-key'
		base_url: 'http://127.0.0.1:18331'
	}
	resp := p.complete(vai.Request{
		model:    'claude-sonnet-5'
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
		api_key:  'test-key'
		base_url: 'http://127.0.0.1:18332'
		retry:    vai.RetryPolicy{
			max_attempts: 5
			base_delay:   5 * time.millisecond
			max_delay:    20 * time.millisecond
		}
	}
	resp := p.complete(vai.Request{
		model:    'claude-sonnet-5'
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
		api_key:  'test-key'
		base_url: 'http://127.0.0.1:18333'
	}
	if _ := p.complete(vai.Request{
		model:    'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) {
		assert false, 'expected an error'
	}
}

fn test_provider_complete_sets_latency_ms() {
	mut server := &http.Server{
		addr:                 '127.0.0.1:18336'
		handler:              SlowHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	defer {
		server.close()
	}

	p := Provider{
		api_key:  'test-key'
		base_url: 'http://127.0.0.1:18336'
	}
	resp := p.complete(vai.Request{
		model:    'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) or {
		assert false, err.msg()
		return
	}
	// SlowHandler sleeps 50ms; give real scheduling jitter plenty of room
	// while still ruling out latency_ms being an unset/stub zero.
	assert resp.latency_ms >= 30
}

// A transport-level failure (here: nothing listens on 127.0.0.1:1, so
// curl can never even connect) must be retried like a retryable HTTP
// status, and must never surface as "HTTP 0", CurlTransport.post_json
// used to return status: 0 as if it were a real (if useless) response
// instead of an error, which made this failure mode skip retry entirely.
fn test_provider_complete_retries_transport_failure() {
	p := Provider{
		api_key:   'test-key'
		base_url:  'http://127.0.0.1:1'
		transport: vai.Transport(vai.CurlTransport{
			connect_timeout_secs: 1
		})
		retry:     vai.RetryPolicy{
			max_attempts: 2
			base_delay:   30 * time.millisecond
			max_delay:    50 * time.millisecond
		}
	}
	if _ := p.complete(vai.Request{
		model:    'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('transport error'), err.msg()
	}
}

fn test_provider_complete_gives_up_after_max_attempts() {
	mut server := start_mock('127.0.0.1:18334', 99, 429)
	defer {
		server.close()
	}

	p := Provider{
		api_key:  'test-key'
		base_url: 'http://127.0.0.1:18334'
		retry:    vai.RetryPolicy{
			max_attempts: 2
			base_delay:   5 * time.millisecond
			max_delay:    10 * time.millisecond
		}
	}
	if _ := p.complete(vai.Request{
		model:    'claude-sonnet-5'
		messages: [vai.user('hi')]
	}) {
		assert false, 'expected an error'
	}
}

fn test_request_headers_defaults_and_overrides() {
	p := Provider{
		api_key: 'k'
		headers: {
			'Anthropic-Beta': 'b1'
			'User-Agent':     'jaid/0.1.0'
		}
	}
	h := p.request_headers()
	assert h['x-api-key'] == 'k'
	assert h['anthropic-version'] == '2023-06-01'
	assert h['anthropic-beta'] == 'b1'
	assert h['user-agent'] == 'jaid/0.1.0'
	assert h.len == 5
}
