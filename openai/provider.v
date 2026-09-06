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
// retryable status up to retry.max_attempts times, respecting the
// server's own Retry-After header when one is sent.
pub fn (p Provider) complete(req vai.Request) !vai.Response {
	body := encode_request(req)
	mut headers := {
		'content-type': 'application/json'
	}
	if p.api_key != '' {
		headers['authorization'] = 'Bearer ${p.api_key}'
	}
	url := '${p.base_url}/chat/completions'

	mut last_status := 0
	mut last_body := ''
	for attempt in 0 .. p.retry.max_attempts {
		http_resp := p.transport.post_json(url, headers, body)!
		if http_resp.status == 200 {
			return decode_response(http_resp.body)
		}
		last_status = http_resp.status
		last_body = http_resp.body
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
	return error('openai: HTTP ${last_status}: ${extract_error_message(last_body)}')
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
