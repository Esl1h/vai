// Package vai is a client for Anthropic and OpenAI-compatible LLM APIs:
// one request/response shape, streaming, cost accounting, and retry. It
// does not flatten provider-specific behavior (thinking, cache control,
// tool use) into a lowest common denominator; those stay visible on the
// types that carry them.
module vai

import json2

pub enum Role {
	user
	assistant
	system
}

pub type Content = ImageContent | RedactedThinking | TextContent | Thinking | ToolResult | ToolUse

pub struct TextContent {
pub:
	text string
}

pub struct ImageContent {
pub:
	media_type string
	data       string // base64
}

pub struct ToolUse {
pub:
	id    string
	name  string
	input json2.Any
}

pub struct ToolResult {
pub:
	tool_use_id string
	content     string
	is_error    bool
}

pub struct Thinking {
pub:
	text string
	// signature is the opaque encrypted reasoning Anthropic returns on
	// every thinking block. The API verifies it when a thinking block is
	// passed back in multi-turn and tool-use conversations, so it must
	// survive a decode/encode round trip untouched.
	signature string
}

pub struct RedactedThinking {

	// data is the opaque encrypted payload of a safety-redacted thinking
	// block. Like Thinking.signature, it must be echoed back unchanged
	// when continuing a conversation; dropping the block breaks the
	// multi-turn protocol.
pub:
	data string
}

pub struct Message {
pub:
	role    Role
	content []Content
}

// user builds a plain-text user message, the common case.
pub fn user(text string) Message {
	return Message{
		role: .user
		content: [Content(TextContent{ text: text })]
	}
}

// assistant builds a plain-text assistant message, for few-shot examples.
pub fn assistant(text string) Message {
	return Message{
		role: .assistant
		content: [Content(TextContent{ text: text })]
	}
}

pub struct ToolDef {
pub:
	name        string
	description string
	// input_schema is raw JSON text (an object), not a typed structure:
	// building it is the caller's job, whether by hand or via a generator.
	input_schema string
}

pub struct Request {
pub mut:
	model       string
	messages    []Message
	system      string
	max_tokens  int = 4096
	temperature f32 = 1.0
	stream      bool
	tools       []ToolDef
}

// Usage carries all four token categories a caller needs to price a
// response. cache_write_tokens and cache_read_tokens matter: skipping them
// makes cost() wrong by an order of magnitude on a long cached session.
pub struct Usage {
pub mut:
	input_tokens       int
	output_tokens      int
	cache_write_tokens int
	cache_read_tokens  int
}

// total_tokens sums all four categories, mainly for display.
pub fn (u Usage) total_tokens() int {
	return u.input_tokens + u.output_tokens + u.cache_write_tokens + u.cache_read_tokens
}

pub struct Response {
pub:
	id          string
	model       string
	content     []Content
	usage       Usage
	stop_reason string
	// latency_ms is wall-clock time for the whole call, set by
	// Provider.complete(). There is no ttft_ms here: complete() never
	// streams, so "time to first token" has nothing to measure, see
	// StreamEvent.at_ms for that, on the streaming path.
	latency_ms i64
}

pub enum EventKind {
	content_delta
	thinking_delta
	usage
	done
	error
}

// StreamEvent is one provider-agnostic streaming event. A stream can carry
// more than one usage event, each a cumulative snapshot with only the
// fields that provider sends at that point (Anthropic: input and cache
// counts on message_start, output_tokens on message_delta). To price a
// stream, keep the last non-zero value of each Usage field across every
// usage event, not just the last event.
pub struct StreamEvent {
pub:
	kind  EventKind
	text  string
	usage Usage
	err   string
	// at_ms is relative to the start of the request; the first
	// content_delta's at_ms is what a caller measures TTFT with.
	at_ms i64
}
