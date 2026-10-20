// Package openai encodes vai.Request into the OpenAI-compatible chat
// completions body shape and decodes its responses. "OpenAI-compatible"
// covers RouteLLM/Abacus, OpenRouter, Ollama, and LM Studio: they all speak
// this same wire format behind a different base_url, so one implementation
// covers all of them.
module openai

import json2
import vai

// encode_request builds the JSON body for POST /chat/completions. Unlike
// Anthropic, there is no separate top-level "system" field: req.system, if
// set, becomes a leading message with role "system".
pub fn encode_request(req vai.Request) string {
	mut m := map[string]json2.Any{}
	m['model'] = req.model
	m['max_tokens'] = req.max_tokens
	// Always sent: 1.0 is the server-side default and there is no way to
	// distinguish "explicitly 1.0" from the struct default to omit it.
	m['temperature'] = req.temperature
	m['messages'] = encode_messages(req)
	if req.tools.len > 0 {
		m['tools'] = encode_tools(req.tools)
	}
	if req.stream {
		m['stream'] = true
		// Without this, OpenAI and Ollama send no usage at all on a stream.
		mut opts := map[string]json2.Any{}
		opts['include_usage'] = true
		m['stream_options'] = json2.Any(opts)
	}
	return m.str()
}

fn encode_messages(req vai.Request) json2.Any {
	mut arr := []json2.Any{}
	if req.system != '' {
		mut sys := map[string]json2.Any{}
		sys['role'] = 'system'
		sys['content'] = req.system
		arr << json2.Any(sys)
	}
	for msg in req.messages {
		mut m := map[string]json2.Any{}
		m['role'] = role_str(msg.role)
		m['content'] = encode_content(msg.content)
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

// encode_content collapses to a plain string when the message is
// text-only, which is what every OpenAI-compatible server expects for the
// common case; it only builds the multi-part array form when there is
// something else (an image) to carry alongside the text.
fn encode_content(blocks []vai.Content) json2.Any {
	if blocks.len == 1 {
		first := blocks[0]
		if first is vai.TextContent {
			return json2.Any(first.text)
		}
	}
	mut arr := []json2.Any{}
	for b in blocks {
		match b {
			vai.TextContent {
				mut part := map[string]json2.Any{}
				part['type'] = 'text'
				part['text'] = b.text
				arr << json2.Any(part)
			}
			vai.ImageContent {
				mut url := map[string]json2.Any{}
				url['url'] = 'data:${b.media_type};base64,${b.data}'
				mut part := map[string]json2.Any{}
				part['type'] = 'image_url'
				part['image_url'] = url
				arr << json2.Any(part)
			}
			else {}
		}
	}
	return arr
}

fn encode_tools(tools []vai.ToolDef) json2.Any {
	mut arr := []json2.Any{}
	for t in tools {
		mut fn_def := map[string]json2.Any{}
		fn_def['name'] = t.name
		fn_def['description'] = t.description
		fn_def['parameters'] = json2.decode[json2.Any](t.input_schema) or { json2.null }

		mut tool := map[string]json2.Any{}
		tool['type'] = 'function'
		tool['function'] = fn_def
		arr << json2.Any(tool)
	}
	return arr
}
