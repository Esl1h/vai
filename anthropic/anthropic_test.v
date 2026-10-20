module anthropic

import vai

fn test_encode_request_basic() {
	req := vai.Request{
		model:      'claude-sonnet-5'
		messages:   [vai.user('hi')]
		max_tokens: 1024
	}
	out := encode_request(req)
	assert out.contains('"model":"claude-sonnet-5"')
	assert out.contains('"max_tokens":1024')
	// The default is left out: Opus 4.7+ rejects any temperature at all.
	assert !out.contains('"temperature"')
	assert out.contains('"role":"user"')
	assert out.contains('"type":"text"')
	assert out.contains('"text":"hi"')
	assert !out.contains('"system"')
	assert !out.contains('"stream"')
}

fn test_encode_request_custom_temperature() {
	req := vai.Request{
		model:       'claude-sonnet-5'
		messages:    [vai.user('hi')]
		max_tokens:  1024
		temperature: 0.5
	}
	out := encode_request(req)
	assert out.contains('"temperature":0.5')
}

fn test_encode_request_with_system_and_stream() {
	req := vai.Request{
		model:    'claude-sonnet-5'
		messages: [vai.user('hi')]
		system:   'be terse'
		stream:   true
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

fn test_decode_response_ignores_non_numeric_usage_field() {
	// A malformed usage field must not be silently coerced into a real-
	// looking 0 via Any.f64()'s default: input_tokens stays unset (its
	// own zero value either way here, but for the right reason), while a
	// sibling field that *is* well-formed still decodes normally.
	raw := '{"id":"msg_9","model":"claude-sonnet-5","content":[],"stop_reason":"end_turn","usage":{"input_tokens":"not a number","output_tokens":7}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.usage.input_tokens == 0
	assert resp.usage.output_tokens == 7
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
		data:  '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}'
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

fn test_decode_stream_event_usage_from_message_start() {
	// message_start is the only event that carries input_tokens and the
	// cache counts (verified against the streaming docs' examples).
	ev := vai.RawSseEvent{
		event: 'message_start'
		data:  '{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5","usage":{"input_tokens":2679,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":3}}}'
	}
	se := decode_stream_event(ev) or {
		assert false, 'expected a usage event'
		return
	}
	assert se.kind == .usage
	assert se.usage.input_tokens == 2679
	assert se.usage.cache_write_tokens == 10
	assert se.usage.cache_read_tokens == 20
	assert se.usage.output_tokens == 3
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

fn test_thinking_block_roundtrips_with_signature() {
	raw := '{"id":"msg_3","model":"claude-sonnet-5","content":[{"type":"thinking","thinking":"pondering","signature":"sig_abc"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.content.len == 1
	c := resp.content[0]
	if c is vai.Thinking {
		assert c.text == 'pondering'
		assert c.signature == 'sig_abc'
	} else {
		assert false, 'expected Thinking'
	}
	req := vai.Request{
		model:      'claude-sonnet-5'
		messages:   [vai.Message{
			role:    .assistant
			content: resp.content
		}]
		max_tokens: 64
	}
	out := encode_request(req)
	assert out.contains('"type":"thinking"')
	assert out.contains('"thinking":"pondering"')
	assert out.contains('"signature":"sig_abc"')
}

fn test_redacted_thinking_block_roundtrips() {
	raw := '{"id":"msg_4","model":"claude-sonnet-5","content":[{"type":"redacted_thinking","data":"enc_blob"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	assert resp.content.len == 1
	c := resp.content[0]
	if c is vai.RedactedThinking {
		assert c.data == 'enc_blob'
	} else {
		assert false, 'expected RedactedThinking'
	}
	req := vai.Request{
		model:      'claude-sonnet-5'
		messages:   [vai.Message{
			role:    .assistant
			content: resp.content
		}]
		max_tokens: 64
	}
	out := encode_request(req)
	assert out.contains('"type":"redacted_thinking"')
	assert out.contains('"data":"enc_blob"')
}

fn test_thinking_block_omitted_display_still_roundtrips() {
	// With display:"omitted" (the default on current models) the thinking
	// field arrives empty and the signature is the only payload; the API
	// rejects a round-trip that drops it.
	raw := '{"id":"msg_5","model":"claude-opus-5","content":[{"type":"thinking","thinking":"","signature":"sig_long_opaque_value"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
	resp := decode_response(raw) or {
		assert false, err.msg()
		return
	}
	c := resp.content[0]
	if c is vai.Thinking {
		assert c.text == ''
		assert c.signature == 'sig_long_opaque_value'
	} else {
		assert false, 'expected Thinking'
	}
}
