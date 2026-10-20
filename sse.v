module vai

// RawSseEvent is one decoded Server-Sent Event frame: the field names come
// straight from the SSE spec, not from any particular LLM provider. What
// the "data" JSON means is a provider's job to interpret, not this file's.
pub struct RawSseEvent {
pub:
	event string
	data  string
	id    string
	// status and err never come from SseParser. A transport sets one of
	// them on a last, synthetic event to report what the event stream
	// itself can't: status is a non-2xx HTTP answer, with its body in
	// data; err is a transport failure (connection refused, a stall).
	status int
	err    string
}

// SseParser turns a stream of lines into RawSseEvent values. It exists
// because V's own SSE support is thin: a Transport that shells out to
// `curl -N` reads stdout one line at a time, so this has to be fed
// incrementally rather than handed a complete response body.
pub struct SseParser {
mut:
	event      string
	data_lines []string
	id         string
}

// feed processes one line, without its trailing newline, and returns a
// completed event when a blank line ends one. Per the SSE spec: fields
// accumulate across lines, a line starting with ":" is a comment and is
// ignored, and a blank line dispatches whatever has accumulated so far.
pub fn (mut p SseParser) feed(line string) ?RawSseEvent {
	if line == '' {
		if p.data_lines.len == 0 && p.event == '' && p.id == '' {
			return none
		}
		ev := RawSseEvent{
			event: p.event
			data:  p.data_lines.join('\n')
			id:    p.id
		}
		p.event = ''
		p.data_lines = []string{}
		p.id = ''
		return ev
	}
	if line.starts_with(':') {
		return none
	}
	if line.starts_with('event:') {
		p.event = line[6..].trim_space()
	} else if line.starts_with('data:') {
		p.data_lines << line[5..].trim_space()
	} else if line.starts_with('id:') {
		p.id = line[3..].trim_space()
	}
	return none
}
