module openai

import vai

fn test_encode_request_text_collapses_to_plain_string() {
	req := vai.Request{
		model: 'llama3'
		messages: [vai.user('hi')]
		max_tokens: 512
	}
	out := encode_request(req)
	assert out.contains('"content":"hi"')
	assert out.contains('"role":"user"')
	assert !out.contains('"content":[')
}

fn test_encode_request_system_becomes_leading_message() {
	req := vai.Request{
		model: 'llama3'
		messages: [vai.user('hi')]
		system: 'be terse'
	}
	out := encode_request(req)
	assert out.contains('"role":"system","content":"be terse"')
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

fn test_decode_stream_event_ignores_empty_delta() {
	ev := vai.RawSseEvent{
		data: '{"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}'
	}
	if _ := decode_stream_event(ev) {
		assert false, 'expected none for an empty delta'
	}
}
