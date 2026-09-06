module anthropic

import json2
import vai

// decode_response parses a complete (non-streaming) POST /v1/messages body.
pub fn decode_response(raw string) !vai.Response {
	val := json2.decode[json2.Any](raw)!
	if val !is map[string]json2.Any {
		return error('expected a JSON object')
	}
	obj := val.as_map()

	id := (obj['id'] or { json2.Any('') }).str()
	model := (obj['model'] or { json2.Any('') }).str()
	stop_reason := (obj['stop_reason'] or { json2.Any('') }).str()

	mut content := []vai.Content{}
	if v := obj['content'] {
		content = decode_content_blocks(v)
	}

	mut usage := vai.Usage{}
	if v := obj['usage'] {
		usage = decode_usage(v.as_map())
	}

	return vai.Response{
		id: id
		model: model
		content: content
		usage: usage
		stop_reason: stop_reason
	}
}

fn decode_content_blocks(v json2.Any) []vai.Content {
	if v !is []json2.Any {
		return []vai.Content{}
	}
	mut out := []vai.Content{}
	for item in v.as_array() {
		if item !is map[string]json2.Any {
			continue
		}
		obj := item.as_map()
		type_val := obj['type'] or { continue }
		match type_val.str() {
			'text' {
				out << vai.Content(vai.TextContent{
					text: (obj['text'] or { json2.Any('') }).str()
				})
			}
			'thinking' {
				out << vai.Content(vai.Thinking{
					text: (obj['thinking'] or { json2.Any('') }).str()
					signature: (obj['signature'] or { json2.Any('') }).str()
				})
			}
			'redacted_thinking' {
				out << vai.Content(vai.RedactedThinking{
					data: (obj['data'] or { json2.Any('') }).str()
				})
			}
			'tool_use' {
				out << vai.Content(vai.ToolUse{
					id: (obj['id'] or { json2.Any('') }).str()
					name: (obj['name'] or { json2.Any('') }).str()
					input: obj['input'] or { json2.null }
				})
			}
			else {}
		}
	}
	return out
}

// decode_usage only accepts a field that is actually a number. Any.f64()
// itself never fails — it silently returns 0 for a non-numeric value —
// which would otherwise make a malformed usage field indistinguishable
// from a real zero. Reporting 0 tokens when the true count is unknown is
// worse than leaving the field at its default: it reads as "this request
// was free" rather than "this wasn't reported."
fn decode_usage(obj map[string]json2.Any) vai.Usage {
	mut u := vai.Usage{}
	if v := obj['input_tokens'] {
		if v is f64 {
			u.input_tokens = int(v)
		}
	}
	if v := obj['output_tokens'] {
		if v is f64 {
			u.output_tokens = int(v)
		}
	}
	if v := obj['cache_creation_input_tokens'] {
		if v is f64 {
			u.cache_write_tokens = int(v)
		}
	}
	if v := obj['cache_read_input_tokens'] {
		if v is f64 {
			u.cache_read_tokens = int(v)
		}
	}
	return u
}

// decode_stream_event translates one raw SSE frame from the Messages API
// streaming format into vai's provider-agnostic StreamEvent. Returns none
// for frames a caller has no use for (ping, content_block_start/stop,
// message_start) rather than inventing a placeholder event for them.
pub fn decode_stream_event(raw vai.RawSseEvent) ?vai.StreamEvent {
	val := json2.decode[json2.Any](raw.data) or { return none }
	if val !is map[string]json2.Any {
		return none
	}
	obj := val.as_map()
	type_val := obj['type'] or { return none }

	match type_val.str() {
		'content_block_delta' {
			return decode_content_block_delta(obj)
		}
		'message_delta' {
			mut usage := vai.Usage{}
			if usage_val := obj['usage'] {
				usage = decode_usage(usage_val.as_map())
			}
			return vai.StreamEvent{
				kind: .usage
				usage: usage
			}
		}
		'message_stop' {
			return vai.StreamEvent{
				kind: .done
			}
		}
		'error' {
			mut msg := ''
			if err_val := obj['error'] {
				if err_val is map[string]json2.Any {
					if m := err_val['message'] {
						msg = m.str()
					}
				}
			}
			return vai.StreamEvent{
				kind: .error
				err: msg
			}
		}
		else {
			return none
		}
	}
}

fn decode_content_block_delta(obj map[string]json2.Any) ?vai.StreamEvent {
	delta_val := obj['delta'] or { return none }
	if delta_val !is map[string]json2.Any {
		return none
	}
	delta := delta_val.as_map()
	delta_type := (delta['type'] or { return none }).str()

	match delta_type {
		'text_delta' {
			return vai.StreamEvent{
				kind: .content_delta
				text: (delta['text'] or { json2.Any('') }).str()
			}
		}
		'thinking_delta' {
			return vai.StreamEvent{
				kind: .thinking_delta
				text: (delta['thinking'] or { json2.Any('') }).str()
			}
		}
		else {
			return none
		}
	}
}
