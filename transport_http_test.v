module vai

import net.http

// echo_handler is a minimal mock server: it never leaves the machine, per
// this project's own rule against hitting real endpoints from tests. It
// echoes the request body back inside a small JSON envelope, and honors an
// X-Test-Status request header so a test can ask for a specific status
// code without needing a route per status.
struct EchoHandler {}

fn (h EchoHandler) handle(req http.Request) http.Response {
	mut status := http.Status.ok
	if code := req.header.get_custom('X-Test-Status', http.HeaderQueryConfig{}) {
		status = unsafe { http.Status(code.int()) }
	}
	mut resp := http.Response{
		body: '{"echo":"${req.data}"}'
	}
	resp.set_status(status)
	return resp
}

fn start_test_server(addr string) &http.Server {
	mut server := &http.Server{
		addr: addr
		handler: EchoHandler{}
		show_startup_message: false
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	return server
}

fn test_native_transport_post_json_success() {
	mut server := start_test_server('127.0.0.1:18321')
	defer {
		server.close()
	}

	t := NativeTransport{}
	resp := t.post_json('http://127.0.0.1:18321/', {
		'Content-Type': 'application/json'
	}, '{"hi":1}') or {
		assert false, err.msg()
		return
	}
	assert resp.status == 200
	assert resp.body.contains('{"hi":1}')
}

fn test_native_transport_post_json_propagates_error_status() {
	mut server := start_test_server('127.0.0.1:18322')
	defer {
		server.close()
	}

	t := NativeTransport{}
	resp := t.post_json('http://127.0.0.1:18322/', {
		'X-Test-Status': '429'
	}, '{}') or {
		assert false, err.msg()
		return
	}
	assert resp.status == 429
}

fn test_native_transport_post_stream_is_unsupported() {
	t := NativeTransport{}
	if _ := t.post_stream('http://example.invalid/', {}, '{}') {
		assert false, 'expected an error'
	}
}
