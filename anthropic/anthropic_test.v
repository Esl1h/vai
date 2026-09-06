module anthropic

import vai

fn test_encode_request_basic() {
	req := vai.Request{
		model: 'claude-sonnet-5'
		messages: [vai.user('hi')]
		max_tokens: 1024
	}
	out := encode_request(req)
	assert out.contains('"model":"claude-sonnet-5"')
	assert out.contains('"max_tokens":1024')
	assert out.contains('"role":"user"')
	assert out.contains('"type":"text"')
	assert out.contains('"text":"hi"')
	assert !out.contains('"system"')
	assert !out.contains('"stream"')
}

fn test_encode_request_with_system_and_stream() {
	req := vai.Request{
		model: 'claude-sonnet-5'
		messages: [vai.user('hi')]
		system: 'be terse'
		stream: true
	}
	out := encode_request(req)
	assert out.contains('"system":"be terse"')
	assert out.contains('"stream":true')
}

fn test_decode_response_text() {
	raw := '{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.id == 'msg_1'
	assert resp.model == 'claude-sonnet-5'
	assert resp.stop_reason == 'end_turn'
	assert resp.content.len == 1
	c := resp.content[0]
	if c is vai.TextContent {
		assert c.text == 'hello'
	} else {
		assert false, 'expected TextContent'
	}
	assert resp.usage.input_tokens == 10
	assert resp.usage.output_tokens == 5
	assert resp.usage.cache_write_tokens == 2
	assert resp.usage.cache_read_tokens == 3
}

fn test_decode_response_tool_use() {
	raw := '{"id":"msg_2","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"tu_1","name":"lookup","input":{"q":"weather"}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.content.len == 1
	c := resp.content[0]
	if c is vai.ToolUse {
		assert c.id == 'tu_1'
		assert c.name == 'lookup'
	} else {
		assert false, 'expected ToolUse'
	}
}

fn test_decode_stream_event_content_delta() {
	ev := vai.RawSseEvent{
		event: 'content_block_delta'
		data: '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .content_delta
	assert se.text == 'Hi'
}

fn test_decode_stream_event_thinking_delta() {
	ev := vai.RawSseEvent{
		data: '{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"pondering"}}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .thinking_delta
	assert se.text == 'pondering'
}

fn test_decode_stream_event_usage_from_message_delta() {
	ev := vai.RawSseEvent{
		data: '{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .usage
	assert se.usage.output_tokens == 42
}

fn test_decode_stream_event_done() {
	ev := vai.RawSseEvent{
		data: '{"type":"message_stop"}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .done
}

fn test_decode_stream_event_error() {
	ev := vai.RawSseEvent{
		data: '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected an event'
		return
	}
	assert se.kind == .error
	assert se.err == 'Overloaded'
}

fn test_decode_stream_event_ignores_unhandled_types() {
	ev := vai.RawSseEvent{
		data: '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
	}
	if _ := decode_stream_event(ev) {
		assert false, 'expected none for content_block_start'
	}
}
