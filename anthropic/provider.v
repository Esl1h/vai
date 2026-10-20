module anthropic

import json2
import time
import vai

pub struct Provider {
pub:
	api_key   string
	base_url  string        = 'https://api.anthropic.com'
	version   string        = '2023-06-01'
	transport vai.Transport = vai.Transport(vai.NativeTransport{})
	retry     vai.RetryPolicy
	// headers are sent on every request, on top of (and overriding) the
	// ones vai sets itself; names are case-insensitive. Use it for an
	// anthropic-beta flag, or for what a gateway in front of the API
	// needs (OpenCode Go routes on x-opencode-session).
	headers map[string]string
}

// request_headers is what complete and stream send: vai's own defaults,
// then p.headers on top, keyed in lower case so an override replaces a
// default instead of sending the header twice.
fn (p Provider) request_headers() map[string]string {
	mut h := {
		'x-api-key':         p.api_key
		'anthropic-version': p.version
		'content-type':      'application/json'
		'user-agent':        vai.user_agent
	}
	for k, v in p.headers {
		h[k.to_lower()] = v
	}
	return h
}

// complete sends req and returns the full response, retrying on a
// retryable HTTP status (rate limiting, a momentary server failure, 529
// overloaded) *and* on a transport-level failure (connection refused,
// DNS failure, a curl timeout) up to retry.max_attempts times, a
// transport error never reaching an HTTP response is exactly the kind of
// transient failure retry exists for, not a reason to give up on the
// first attempt. It respects the server's own Retry-After header when
// one is sent, falling back to backoff_delay otherwise.
pub fn (p Provider) complete(req vai.Request) !vai.Response {
	body := encode_request(req)
	headers := p.request_headers()
	url := '${p.base_url}/v1/messages'

	sw := time.new_stopwatch()
	mut final_err := 'no attempts were made'
	for attempt in 0 .. p.retry.max_attempts {
		http_resp := p.transport.post_json(url, headers, body) or {
			final_err = 'transport error: ${err.msg()}'
			if attempt < p.retry.max_attempts - 1 {
				time.sleep(p.retry.backoff_delay(attempt))
			}
			continue
		}
		if http_resp.status == 200 {
			resp := decode_response(http_resp.body)!
			return vai.Response{
				...resp
				latency_ms: sw.elapsed().milliseconds()
			}
		}
		final_err = 'HTTP ${http_resp.status}: ${extract_error_message(http_resp.body)}'
		if !vai.retryable_status(http_resp.status) {
			break
		}
		if attempt < p.retry.max_attempts - 1 {
			delay := if http_resp.retry_after != '' {
				vai.parse_retry_after(http_resp.retry_after) or { p.retry.backoff_delay(attempt) }
			} else {
				p.retry.backoff_delay(attempt)
			}
			time.sleep(delay)
		}
	}
	return error('anthropic: ${final_err}')
}

// stream sends req with stream: true and turns the response into
// vai.StreamEvent values on the returned channel, closed once the
// underlying transport's raw SSE channel closes.
//
// A non-2xx answer (e.g. a 429 JSON body instead of an event stream) or
// a transport failure arrives as one last .error event (with
// CurlTransport, which reports both). Unlike complete(), stream does not
// retry.
pub fn (p Provider) stream(req vai.Request) !chan vai.StreamEvent {
	mut streaming_req := req
	streaming_req.stream = true
	body := encode_request(streaming_req)
	headers := p.request_headers()
	url := '${p.base_url}/v1/messages'

	raw_ch := p.transport.post_stream(url, headers, body)!
	out := chan vai.StreamEvent{cap: 32}
	spawn pump_anthropic_events(raw_ch, out)
	return out
}

// pump_anthropic_events stamps every event with at_ms, the time since
// the stream started, which is what a caller measures TTFT from (the
// first content_delta's at_ms) and generation rate from (output length
// over the span between the first and last delta's at_ms).
fn pump_anthropic_events(raw_ch chan vai.RawSseEvent, out chan vai.StreamEvent) {
	sw := time.new_stopwatch()
	for {
		raw := <-raw_ch or { break }
		if raw.status != 0 || raw.err != '' {
			msg := if raw.status != 0 {
				'HTTP ${raw.status}: ${extract_error_message(raw.data)}'
			} else {
				'transport error: ${raw.err}'
			}
			out <- vai.StreamEvent{
				kind:  .error
				err:   'anthropic: ${msg}'
				at_ms: sw.elapsed().milliseconds()
			}
			continue
		}
		if ev := decode_stream_event(raw) {
			out <- vai.StreamEvent{
				...ev
				at_ms: sw.elapsed().milliseconds()
			}
		}
	}
	out.close()
}

// extract_error_message pulls error.message out of Anthropic's error
// body ({"type":"error","error":{"type":...,"message":...}}), falling
// back to the raw body when it isn't that shape.
fn extract_error_message(body string) string {
	val := json2.decode[json2.Any](body) or { return body }
	if val !is map[string]json2.Any {
		return body
	}
	obj := val.as_map()
	err_val := obj['error'] or { return body }
	err_obj := err_val.as_map()
	msg := err_obj['message'] or { return body }
	return msg.str()
}
