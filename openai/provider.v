module openai

import json2
import time
import vai

// Provider targets any OpenAI-compatible endpoint: RouteLLM/Abacus,
// OpenRouter, Ollama, LM Studio. base_url is what actually selects the
// provider; there is no separate config per backend.
pub struct Provider {
pub:
	api_key   string
	base_url  string @[required]
	transport vai.Transport = vai.Transport(vai.NativeTransport{})
	retry     vai.RetryPolicy
}

// complete sends req and returns the full response, retrying on a
// retryable HTTP status *and* on a transport-level failure (connection
// refused, DNS failure, a curl timeout) up to retry.max_attempts times —
// a transport error never reaching an HTTP response is exactly the kind
// of transient failure retry exists for, not a reason to give up on the
// first attempt. Respects the server's own Retry-After header when one
// is sent, falling back to backoff_delay otherwise.
pub fn (p Provider) complete(req vai.Request) !vai.Response {
	body := encode_request(req)
	mut headers := {
		'content-type': 'application/json'
	}
	if p.api_key != '' {
		headers['authorization'] = 'Bearer ${p.api_key}'
	}
	url := '${p.base_url}/chat/completions'

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
	return error('openai: ${final_err}')
}

// stream sends req with stream: true and turns the response into
// vai.StreamEvent values on the returned channel, closed once the
// underlying transport's raw SSE channel closes.
//
// Known gap: unlike complete(), stream does not retry and does not see
// the HTTP status of the request at all — Transport.post_stream returns
// only a channel, no status code. A non-2xx error response gets its body
// fed to the SSE parser like any other line and most likely produces zero
// events rather than a clear error. Fixing this needs a Transport
// interface change that hasn't been done yet.
pub fn (p Provider) stream(req vai.Request) !chan vai.StreamEvent {
	mut streaming_req := req
	streaming_req.stream = true
	body := encode_request(streaming_req)
	mut headers := {
		'content-type': 'application/json'
	}
	if p.api_key != '' {
		headers['authorization'] = 'Bearer ${p.api_key}'
	}
	url := '${p.base_url}/chat/completions'

	raw_ch := p.transport.post_stream(url, headers, body)!
	out := chan vai.StreamEvent{ cap: 32 }
	spawn pump_openai_events(raw_ch, out)
	return out
}

// pump_openai_events stamps every event with at_ms, the time since the
// stream started — see anthropic.pump_anthropic_events for why.
fn pump_openai_events(raw_ch chan vai.RawSseEvent, out chan vai.StreamEvent) {
	sw := time.new_stopwatch()
	for {
		raw := <-raw_ch or { break }
		if ev := decode_stream_event(raw) {
			out <- vai.StreamEvent{
				...ev
				at_ms: sw.elapsed().milliseconds()
			}
		}
	}
	out.close()
}

// extract_error_message pulls error.message out of an OpenAI-compatible
// error body ({"error":{"message":...,"type":...}}), falling back to the
// raw body when it isn't that shape.
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
