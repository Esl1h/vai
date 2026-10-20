module vai

// user_agent is the User-Agent both providers send unless the caller
// overrides it in Provider.headers. A tool built on vai should send its
// own name: some gateways (OpenCode Go) ask clients to identify
// themselves instead of looking like a generic HTTP library.
pub const user_agent = 'vai/0.1.0'

// HttpResponse is deliberately smaller than what an HTTP client normally
// returns: callers only ever need the status, the body, and (for retry)
// the Retry-After header to build a Response or a retry decision out of.
pub struct HttpResponse {
pub:
	status int
	body   string
	// retry_after is the raw Retry-After header value, empty if the
	// response didn't send one. Feed it to parse_retry_after.
	retry_after string
}

// Transport is the one seam vai has for actually reaching a provider.
// post_stream returns raw, provider-agnostic SSE frames: turning those
// into vai.StreamEvent is a provider's job (see anthropic.decode_stream_event,
// openai.decode_stream_event), not the transport's.
//
// There are two implementations for a reason, not by accident: V's own
// net.http has no streaming response support, so NativeTransport (net.http)
// covers the common non-streaming case with zero external dependencies,
// while CurlTransport shells out to `curl -N` for streaming. Neither one
// alone covers everything vai needs to do.
pub interface Transport {
	post_json(url string, headers map[string]string, body string) !HttpResponse
	post_stream(url string, headers map[string]string, body string) !chan RawSseEvent
}
