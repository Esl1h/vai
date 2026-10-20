# vai

[![CI](https://github.com/Esl1h/vai/actions/workflows/ci.yml/badge.svg)](https://github.com/Esl1h/vai/actions/workflows/ci.yml)

A [V](https://vlang.io) module: one request/response shape, streaming, cost accounting, and retry for Anthropic and OpenAI-compatible LLM APIs. "OpenAI-compatible" covers RouteLLM/Abacus, OpenRouter, Ollama, and LM Studio, since they all speak the same wire format behind a different `base_url`.

This exists because nothing like it does in V today: every tool that wants to call Claude or GPT from V currently hand-rolls JSON encoding, has no streaming story, and gets token cost wrong by skipping the cache-read/cache-write fields. `vai` is the shared foundation meant to sit under `ccstat`, `llmbench`, and `jaid`.

## Install

```sh
v install https://github.com/Esl1h/vai
```

## What's here

- **Core types** (`types.v`): `Message`, `Content` (a sum type: text, image, tool use, tool result, thinking, redacted thinking), `Usage`, `Request`, `Response`, `StreamEvent`.
- **Cost accounting** (`cost.v`): a real, sourced pricing table for Anthropic's current models (Opus 5, Sonnet 5, Haiku 4.5, Claude Fable 5.1), all four token categories including cache write/read, and a `PriceBook` for adding or overriding prices without forking the module.
- **Retry** (`retry.v`): which HTTP statuses are worth retrying, and exponential backoff with jitter.
- **SSE framing** (`sse.v`): a provider-agnostic incremental parser (`SseParser.feed(line)`), because a transport reads a stream one line at a time, not as one complete body.
- **`local`** (`local/`): reads the session files coding agents already keep on disk for token usage, model, and timing: Claude Code's transcripts (`~/.claude/projects/**/*.jsonl`, subagent transcripts folded into their session), and pi's and omp's (`~/.pi/agent/sessions`, `~/.omp/agent/sessions`, pi's format version 3). `vai.local.opencode` reads OpenCode's per-session totals from its SQLite database (`~/.local/share/opencode/opencode.db`), as a module of its own since it links libsqlite3 (`sqlite-devel` or `libsqlite3-dev` at build time). Read defensively, since none of these formats is a public contract.
- **`anthropic`** (`anthropic/`) and **`openai`** (`openai/`): request encoding, response decoding, and stream-event decoding for each provider's actual wire format. Each is tested against realistic fixtures, not live calls.
- **Transport** (`transport.v`, `transport_http.v`, `transport_curl.v`): the `Transport` interface, `NativeTransport` (`net.http`, non-streaming only), and `CurlTransport`, which shells out to `curl` for both request kinds and is what makes streaming work at all, since `net.http` has none. Handles the partial-line buffering across non-blocking reads itself, since `os.Process` doesn't give you a line-buffered read.
- **`Provider`** (`anthropic.Provider`, `openai.Provider`): `complete(req) !vai.Response` with retry (rate limiting, a momentary server failure, Anthropic's 529, respecting the server's own `Retry-After` header), and `stream(req) !chan vai.StreamEvent`, where a non-2xx answer or a curl failure (connection refused, a stalled stream) ends the stream with one `.error` event carrying the provider's message. Both tested against a local mock server, `complete()`'s retry path with a fake 429-then-succeed handler, `stream()` end-to-end through a real `curl` subprocess parsing a real SSE body.

## What's not here yet

- **`Provider.count_tokens()`** and **`Provider.models()`**. Nothing calls either endpoint yet.
- **OpenAI-side tool use.** `tools` are sent, but `message.tool_calls` in the answer is not decoded yet: a tool-use reply arrives as empty content with `stop_reason: "tool_calls"`. Anthropic's `tool_use` blocks are decoded.
- **`stream()` doesn't retry.** `complete()` does; a streaming call that fails before or during the stream is the caller's problem to retry today.
- Any actual call to a live Anthropic or OpenAI-compatible endpoint. Every test here runs against a fixture or a local mock `net.http.Server`, this project follows the same rule as this author's other V projects: tests never send traffic to a real third-party endpoint. Outside the test suite, `complete()` and `stream()` were run by hand against a local Ollama over both dialects (OpenAI-compatible and Anthropic, with and without a reasoning model), z.AI's GLM Coding Plan over both dialects (`https://api.z.ai/api/coding/paas/v4`, `https://api.z.ai/api/anthropic`), and OpenCode Go's error paths; never against Anthropic's or OpenAI's own API.

## Usage (what works today)

```v
import vai
import vai.anthropic

p := anthropic.Provider{
	api_key: os.getenv('ANTHROPIC_API_KEY')
}
resp := p.complete(vai.Request{
	model:      'claude-sonnet-5'
	messages:   [vai.user('summarize this log')]
	max_tokens: 1024
})!
println(resp.content)
println(vai.cost(resp.model, resp.usage).total())
```

Same shape for any OpenAI-compatible endpoint, Ollama, OpenRouter, RouteLLM/Abacus, LM Studio, just point `base_url` at it:

```v
import vai
import vai.openai

p := openai.Provider{
	base_url: 'http://localhost:11434/v1'
	// api_key: '...' // most local servers don't need one
}
resp := p.complete(vai.Request{
	model:    'llama3'
	messages: [vai.user('summarize this log')]
})!
```

`headers` adds request headers to either provider, or overrides vai's own (names are case-insensitive). A tool built on vai should name itself in `User-Agent`, the default is `vai/<version>`. [OpenCode Go](https://opencode.ai/docs/go/) also rejects a request without a stable `x-opencode-session` per conversation:

```v
p := openai.Provider{
	base_url: 'https://opencode.ai/zen/go/v1'
	api_key:  os.getenv('OPENCODE_API_KEY')
	headers:  {
		'user-agent':         'jaid/0.1.0'
		'x-opencode-session': session_id
	}
}
```

Streaming needs `CurlTransport` explicitly, the default is `NativeTransport`, which can't stream:

```v
import vai
import vai.anthropic

p := anthropic.Provider{
	api_key:   os.getenv('ANTHROPIC_API_KEY')
	transport: vai.CurlTransport{}
}
ch := p.stream(vai.Request{
	model:    'claude-sonnet-5'
	messages: [vai.user('summarize this log')]
	stream:   true
})!
for {
	ev := <-ch or { break }
	if ev.kind == .content_delta {
		print(ev.text)
	}
}
```

Reading local session state:

```v
import vai.local

sessions := local.claude_sessions()!
for s in sessions {
	println('${s.id}: ${s.usage.total_tokens()} tokens, model ${s.model}')
}
```

`local.pi_sessions()`, `local.omp_sessions()` and `opencode.sessions()` (`import vai.local.opencode`) return the same `Session` shape.

## Development

```sh
make check   # fmt-check + vet + test
make test
make fmt
```

`v test .` is slow once `net.http` is in the dependency graph (dozens of seconds), that's normal.

## Scope

No tokenizer of its own: use `usage` from a response, or a provider's token-counting endpoint once `Provider.count_tokens()` exists. No abstraction that flattens Anthropic and OpenAI's real differences (thinking blocks, cache control, tool use) into a lowest common denominator, each provider submodule encodes and decodes its own shape. No agent loop, memory, or RAG: that's application scope, not a client library's.

## License

MIT
