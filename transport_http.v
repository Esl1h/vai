module vai

import net.http
import time

// NativeTransport uses V's own net.http client: zero external
// dependencies, but no streaming support. It exists for the common case
// (a single request, a single response) and for environments where
// shelling out to curl isn't an option.
pub struct NativeTransport {

	// timeout_secs bounds each socket read and write. net.http's own
	// default is 30 s, which a non-streaming completion on a slow local
	// model exceeds before the first byte arrives, and then every retry
	// attempt burns the same 30 s again. 0 or less keeps net.http's default.
pub:
	timeout_secs int = 300
}

// post_json sends one request and returns the complete response.
pub fn (t NativeTransport) post_json(url string, headers map[string]string, body string) !HttpResponse {
	mut req := http.new_request(.post, url, body)
	if t.timeout_secs > 0 {
		req.read_timeout = i64(t.timeout_secs) * i64(time.second)
		req.write_timeout = i64(t.timeout_secs) * i64(time.second)
	}
	req.header.add_custom_map(headers)!
	resp := req.do()!
	return HttpResponse{
		status:      resp.status_code
		body:        resp.body
		retry_after: resp.header.get(.retry_after) or { '' }
	}
}

// post_stream always fails: net.http has no streaming response support in
// this V version. Use CurlTransport for any request with stream: true.
pub fn (t NativeTransport) post_stream(url string, headers map[string]string, body string) !chan RawSseEvent {
	return error('NativeTransport does not support streaming; use CurlTransport')
}
