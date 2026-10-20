module openai

import vai
import json2

fn test_encode_request_text_collapses_to_plain_string() {
	req := vai.Request{
		model:      'llama3'
		messages:   [vai.user('hi')]
		max_tokens: 512
	}
	out := encode_request(req)
	assert out.contains('"content":"hi"')
	assert out.contains('"role":"user"')
	assert out.contains('"temperature":1')
	assert !out.contains('"content":[')
}

fn test_encode_request_system_becomes_leading_message() ! {
	req := vai.Request{
		model:    'llama3'
		messages: [vai.user('hi')]
		system:   'be terse'
	}
	out := encode_request(req)
	// Decoded rather than matched as text: json2 does not guarantee key order.
	msgs := (json2.decode[json2.Any](out)!.as_map()['messages'] or { json2.Any('') }).as_array()
	assert msgs.len == 2
	first := msgs[0].as_map()
	assert (first['role'] or { json2.Any('') }).str() == 'system'
	assert (first['content'] or { json2.Any('') }).str() == 'be terse'
}

fn test_encode_request_stream_asks_for_usage() ! {
	mut req := vai.Request{
		model:    'llama3'
		messages: [vai.user('hi')]
	}
	plain := json2.decode[json2.Any](encode_request(req))!.as_map()
	assert 'stream_options' !in plain
	req.stream = true
	streamed := json2.decode[json2.Any](encode_request(req))!.as_map()
	opts := (streamed['stream_options'] or { json2.Any('') }).as_map()
	assert (opts['include_usage'] or { json2.Any(false) }).bool()
}

fn test_decode_response_text() {
	raw := '{"id":"chatcmpl-1","model":"llama3","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.id == 'chatcmpl-1'
	assert resp.stop_reason == 'stop'
	assert resp.usage.input_tokens == 10
	assert resp.usage.output_tokens == 5
	assert resp.content.len == 1
	c := resp.content[0]
	if c is vai.TextContent {
		assert c.text == 'hello'
	} else {
		assert false, 'expected TextContent'
	}
}

fn test_decode_response_ignores_non_numeric_usage_field() {
	// A malformed usage field must not be silently coerced into a real-
	// looking 0 via Any.f64()'s default: a sibling field that *is*
	// well-formed still decodes normally.
	raw := '{"id":"chatcmpl-2","model":"llama3","choices":[],"usage":{"prompt_tokens":"lots","completion_tokens":7}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.usage.input_tokens == 0
	assert resp.usage.output_tokens == 7
}

fn test_decode_stream_event_content_delta() {
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .content_delta
	assert se.text == 'Hi'
}

fn test_decode_stream_event_done_sentinel() {
	ev := vai.RawSseEvent{
		data: '[DONE]'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .done
}

fn test_decode_stream_event_usage_when_present() {
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .usage
	assert se.usage.input_tokens == 3
	assert se.usage.output_tokens == 4
}

fn test_decode_response_null_content_is_not_the_text_null() {
	// A tool_calls answer carries "content": null; Any.str() on a Null
	// yields the word "null", which must not become a TextContent.
	raw := '{"id":"chatcmpl-3","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.content.len == 0
	assert resp.stop_reason == 'tool_calls'
}

fn test_decode_stream_event_null_content_with_reasoning_is_thinking() {
	// Reasoning models stream chunks with "content": null next to a
	// reasoning field; that is a thinking delta, never a "null" text one.
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":null,"reasoning_content":"hmm"},"finish_reason":null}]}'
	}
	got := decode_stream_event(ev) or {
		assert false, 'expected a thinking delta'
		return
	}
	assert got.kind == .thinking_delta
	assert got.text == 'hmm'
}

fn test_decode_stream_event_ignores_null_content_delta() {
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}'
	}
	if _ := decode_stream_event(ev) {
		assert false, 'expected none for a null content delta'
	}
}

fn test_decode_stream_event_ollama_reasoning_delta() {
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"The user"},"finish_reason":null}]}'
	}
	got := decode_stream_event(ev) or {
		assert false, 'expected a thinking delta'
		return
	}
	assert got.kind == .thinking_delta
	assert got.text == 'The user'
}

fn test_decode_stream_event_text_wins_over_reasoning() {
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[{"index":0,"delta":{"content":"Four.","reasoning":"tail"},"finish_reason":null}]}'
	}
	got := decode_stream_event(ev) or {
		assert false, 'expected a content delta'
		return
	}
	assert got.kind == .content_delta
	assert got.text == 'Four.'
}

fn test_decode_response_reasoning_becomes_thinking() {
	// Ollama's shape; DeepSeek and vLLM use reasoning_content instead.
	for field in ['reasoning', 'reasoning_content'] {
		raw := '{"id":"c1","model":"qwen3.8:27b","choices":[{"index":0,"message":{"role":"assistant","content":"Four.","${field}":"2+2 is 4"},"finish_reason":"stop"}]}'
		resp := decode_response(raw) or {
			assert false, err.msg()
			return
		}
		assert resp.content.len == 2
		first := resp.content[0]
		assert first is vai.Thinking
		if first is vai.Thinking {
			assert first.text == '2+2 is 4'
		}
		second := resp.content[1]
		assert second is vai.TextContent
	}
}

fn test_encode_request_drops_thinking_from_history() {
	req := vai.Request{
		model:    'qwen3.8:27b'
		messages: [
			vai.user('2+2?'),
			vai.Message{
				role:    .assistant
				content: [vai.Content(vai.Thinking{
					text: '2+2 is 4'
				}), vai.Content(vai.TextContent{
					text: 'Four.'
				})]
			},
			vai.user('and 3+3?'),
		]
	}
	out := encode_request(req)
	assert out.contains('"content":"Four."')
	assert !out.contains('2+2 is 4')
}

fn test_decode_stream_event_ignores_empty_delta() {
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}'
	}
	if _ := decode_stream_event(ev) {
		assert false, 'expected none for an empty delta'
	}
}
