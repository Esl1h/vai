// Package anthropic encodes vai.Request into Anthropic's Messages API body
// shape and decodes its responses (both a full message and a stream) back
// into vai's types. It has no transport of its own; a caller supplies the
// bytes however it gets them (net.http, a curl subprocess, a mock server).
module anthropic

import json2
import vai

// encode_request builds the JSON body for POST /v1/messages.
pub fn encode_request(req vai.Request) string {
	mut m := map[string]json2.Any{}
	m['model'] = req.model
	m['max_tokens'] = req.max_tokens
	// Omitted at 1.0, the API's own default, so leaving it out means the
	// same thing. Sending it is not harmless: Opus 4.7 and later (Opus 5,
	// Opus 5.5, Fable) reject any temperature, even 1.0, with a 400, while
	// Sonnet 5/5.5 and Haiku 5.5 only reject a non-default value.
	if req.temperature != 1.0 {
		m['temperature'] = req.temperature
	}
	m['messages'] = encode_messages(req.messages)
	if req.system != '' {
		m['system'] = req.system
	}
	if req.tools.len > 0 {
		m['tools'] = encode_tools(req.tools)
	}
	if req.stream {
		m['stream'] = true
	}
	return m.str()
}

fn encode_messages(messages []vai.Message) json2.Any {
	mut arr := []json2.Any{}
	for msg in messages {
		mut m := map[string]json2.Any{}
		m['role'] = role_str(msg.role)
		m['content'] = encode_content_blocks(msg.content)
		arr << json2.Any(m)
	}
	return arr
}

fn role_str(r vai.Role) string {
	return match r {
		.user { 'user' }
		.assistant { 'assistant' }
		.system { 'system' }
	}
}

fn encode_content_blocks(blocks []vai.Content) json2.Any {
	mut arr := []json2.Any{}
	for b in blocks {
		arr << encode_content_block(b)
	}
	return arr
}

fn encode_content_block(c vai.Content) json2.Any {
	return match c {
		vai.TextContent {
			mut m := map[string]json2.Any{}
			m['type'] = 'text'
			m['text'] = c.text
			json2.Any(m)
		}
		vai.ImageContent {
			mut src := map[string]json2.Any{}
			src['type'] = 'base64'
			src['media_type'] = c.media_type
			src['data'] = c.data
			mut m := map[string]json2.Any{}
			m['type'] = 'image'
			m['source'] = src
			json2.Any(m)
		}
		vai.ToolUse {
			mut m := map[string]json2.Any{}
			m['type'] = 'tool_use'
			m['id'] = c.id
			m['name'] = c.name
			m['input'] = c.input
			json2.Any(m)
		}
		vai.ToolResult {
			mut m := map[string]json2.Any{}
			m['type'] = 'tool_result'
			m['tool_use_id'] = c.tool_use_id
			m['content'] = c.content
			if c.is_error {
				m['is_error'] = true
			}
			json2.Any(m)
		}
		vai.Thinking {
			mut m := map[string]json2.Any{}
			m['type'] = 'thinking'
			m['thinking'] = c.text
			m['signature'] = c.signature
			json2.Any(m)
		}
		vai.RedactedThinking {
			mut m := map[string]json2.Any{}
			m['type'] = 'redacted_thinking'
			m['data'] = c.data
			json2.Any(m)
		}
	}
}

fn encode_tools(tools []vai.ToolDef) json2.Any {
	mut arr := []json2.Any{}
	for t in tools {
		mut m := map[string]json2.Any{}
		m['name'] = t.name
		m['description'] = t.description
		m['input_schema'] = json2.decode[json2.Any](t.input_schema) or { json2.null }
		arr << json2.Any(m)
	}
	return arr
}
