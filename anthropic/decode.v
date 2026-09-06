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

fn decode_usage(obj map[string]json2.Any) vai.Usage {
	mut u := vai.Usage{}
	if v := obj['input_tokens'] {
		u.input_tokens = int(v.f64())
	}
	if v := obj['output_tokens'] {
		u.output_tokens = int(v.f64())
	}
	if v := obj['cache_creation_input_tokens'] {
		u.cache_write_tokens = int(v.f64())
	}
	if v := obj['cache_read_input_tokens'] {
		u.cache_read_tokens = int(v.f64())
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
