module vai

// HttpResponse is deliberately smaller than what an HTTP client normally
// returns: callers only ever need the status and the body to build a
// Response or an RpcError-style failure out of it.
pub struct HttpResponse {
pub:
	status int
	body   string
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
