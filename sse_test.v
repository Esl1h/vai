module vai

fn test_sse_parser_single_event() {
	mut p := SseParser{}
	assert p.feed('event: message_start') == none
	assert p.feed('data: {"type":"message_start"}') == none
	ev := p.feed('') or {
		assert false, 'expected an event'
		return
	}
	assert ev.event == 'message_start'
	assert ev.data == '{"type":"message_start"}'
}

fn test_sse_parser_joins_multiline_data() {
	mut p := SseParser{}
	p.feed('data: line one') or {}
	p.feed('data: line two') or {}
	ev := p.feed('') or {
		assert false, 'expected an event'
		return
	}
	assert ev.data == 'line one\nline two'
}

fn test_sse_parser_ignores_comments() {
	mut p := SseParser{}
	assert p.feed(': keep-alive') == none
	p.feed('data: hi') or {}
	ev := p.feed('') or {
		assert false, 'expected an event'
		return
	}
	assert ev.data == 'hi'
}

fn test_sse_parser_ignores_stray_blank_lines() {
	mut p := SseParser{}
	assert p.feed('') == none
}

fn test_sse_parser_handles_two_events_back_to_back() {
	mut p := SseParser{}
	p.feed('event: a') or {}
	p.feed('data: 1') or {}
	first := p.feed('') or {
		assert false, 'expected first event'
		return
	}
	p.feed('event: b') or {}
	p.feed('data: 2') or {}
	second := p.feed('') or {
		assert false, 'expected second event'
		return
	}
	assert first.event == 'a'
	assert first.data == '1'
	assert second.event == 'b'
	assert second.data == '2'
}

fn test_sse_parser_captures_id() {
	mut p := SseParser{}
	p.feed('id: 42') or {}
	p.feed('data: x') or {}
	ev := p.feed('') or {
		assert false, 'expected an event'
		return
	}
	assert ev.id == '42'
}
