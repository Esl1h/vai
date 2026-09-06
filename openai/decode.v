module openai

import json2
import vai

// decode_response parses a complete (non-streaming) chat completion body.
pub fn decode_response(raw string) !vai.Response {
	val := json2.decode[json2.Any](raw)!
	if val !is map[string]json2.Any {
		return error('expected a JSON object')
	}
	obj := val.as_map()

	id := (obj['id'] or { json2.Any('') }).str()
	model := (obj['model'] or { json2.Any('') }).str()

	mut content := []vai.Content{}
	mut stop_reason := ''
	if choices_val := obj['choices'] {
		if choices_val is []json2.Any && choices_val.len > 0 {
			first := choices_val[0]
			if first is map[string]json2.Any {
				if fr := first['finish_reason'] {
					stop_reason = fr.str()
				}
				if msg_val := first['message'] {
					if msg_val is map[string]json2.Any {
						if text_val := msg_val['content'] {
							content = [
								vai.Content(vai.TextContent{ text: text_val.str() }),
							]
						}
					}
				}
			}
		}
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

// decode_usage maps OpenAI's field names onto vai.Usage. Cache accounting
// is not part of the OpenAI-compatible surface generically, so
// cache_write_tokens/cache_read_tokens stay zero: any provider that adds
// its own cache fields on top of this shape isn't covered yet.
//
// Only a field that is actually a number is accepted. Any.f64() itself
// never fails, it silently returns 0 for a non-numeric value, which
// would otherwise make a malformed usage field indistinguishable from a
// real zero. Reporting 0 tokens when the true count is unknown is worse
// than leaving the field at its default: it reads as "this request was
// free" rather than "this wasn't reported."
fn decode_usage(obj map[string]json2.Any) vai.Usage {
	mut u := vai.Usage{}
	if v := obj['prompt_tokens'] {
		if v is f64 {
			u.input_tokens = int(v)
		}
	}
	if v := obj['completion_tokens'] {
		if v is f64 {
			u.output_tokens = int(v)
		}
	}
	return u
}

// decode_stream_event translates one raw SSE frame from the
// chat.completions streaming format. OpenAI-compatible servers use only
// "data:" lines (no "event:" field) and end the stream with the literal
// line "data: [DONE]" rather than a distinct event type.
pub fn decode_stream_event(raw vai.RawSseEvent) ?vai.StreamEvent {
	if raw.data.trim_space() == '[DONE]' {
		return vai.StreamEvent{
			kind: .done
		}
	}
	val := json2.decode[json2.Any](raw.data) or { return none }
	if val !is map[string]json2.Any {
		return none
	}
	obj := val.as_map()

	if usage_val := obj['usage'] {
		if usage_val is map[string]json2.Any {
			return vai.StreamEvent{
				kind: .usage
				usage: decode_usage(usage_val)
			}
		}
	}

	choices_val := obj['choices'] or { return none }
	choices := choices_val.as_array()
	if choices.len == 0 {
		return none
	}
	first := choices[0].as_map()
	delta_val := first['delta'] or { return none }
	delta := delta_val.as_map()
	text_val := delta['content'] or { return none }
	text := text_val.str()
	if text == '' {
		return none
	}
	return vai.StreamEvent{
		kind: .content_delta
		text: text
	}
}
