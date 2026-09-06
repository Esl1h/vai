module anthropic

import json2
import time
import vai

pub struct Provider {
pub:
	api_key   string
	base_url  string = 'https://api.anthropic.com'
	version   string = '2023-06-01'
	transport vai.Transport = vai.Transport(vai.NativeTransport{})
	retry     vai.RetryPolicy
}

// complete sends req and returns the full response, retrying on a
// retryable status (rate limiting, a momentary server failure, 529
// overloaded) up to retry.max_attempts times. It respects the server's
// own Retry-After header when one is sent, falling back to backoff_delay
// otherwise.
pub fn (p Provider) complete(req vai.Request) !vai.Response {
	body := encode_request(req)
	headers := {
		'x-api-key':         p.api_key
		'anthropic-version': p.version
		'content-type':      'application/json'
	}
	url := '${p.base_url}/v1/messages'

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
	return error('anthropic: HTTP ${last_status}: ${extract_error_message(last_body)}')
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
