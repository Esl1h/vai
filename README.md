# vai

[![CI](https://github.com/Esl1h/vai/actions/workflows/ci.yml/badge.svg)](https://github.com/Esl1h/vai/actions/workflows/ci.yml)

A [V](https://vlang.io) module: one request/response shape, streaming, cost accounting, and retry for Anthropic and OpenAI-compatible LLM APIs. "OpenAI-compatible" covers Ollama, z.AI (GLM), OpenCode Go, RouteLLM/Abacus, OpenRouter, and LM Studio, since they all speak the same wire format behind a different `base_url`; servers that also speak Anthropic's Messages API (Ollama, z.AI) work with the Anthropic provider the same way. It also reads the token usage that Claude Code, OpenCode, pi, and omp already keep on disk.

This exists because nothing like it does in V today: every tool that wants to call Claude or GPT from V currently hand-rolls JSON encoding, has no streaming story, and gets token cost wrong by skipping the cache-read/cache-write fields. `vai` is the shared foundation meant to sit under `ccstat`, `llmbench`, and `jaid`.

## Install

```sh
v install https://github.com/Esl1h/vai
```

Streaming needs `curl` on the host. `vai.local.opencode` alone needs the SQLite headers at build time (`sqlite-devel` on Fedora, `libsqlite3-dev` on Debian/Ubuntu; macOS ships them); nothing else in vai links a C library.

## What's here

- **Core types** (`types.v`): `Message`, `Content` (a sum type: text, image, tool use, tool result, thinking, redacted thinking), `Usage`, `Request`, `Response`, `StreamEvent`.
- **Cost accounting** (`cost.v`): Anthropic's [published prices](https://platform.claude.com/docs/en/about-claude/pricing) as of 2026-10-20 for Opus 5.5, Sonnet 5.5, Haiku 5.5, Opus 5, Sonnet 5, Haiku 4.5, and Claude Fable 5.1, all four token categories including cache write/read, Haiku 5.5's higher price for prompts over 100,000 tokens (decided per request, so price one response's usage, not a sum), and a `PriceBook` for adding or overriding prices without forking the module. A model not in the table (every non-Anthropic model, for one) comes back as `Cost{unknown: true}`, never as zero.
- **Retry** (`retry.v`): which HTTP statuses are worth retrying, and exponential backoff with jitter.
- **SSE framing** (`sse.v`): a provider-agnostic incremental parser (`SseParser.feed(line)`), because a transport reads a stream one line at a time, not as one complete body.
- **`local`** (`local/`): reads the session files coding agents already keep on disk for token usage, model, and timing: Claude Code's transcripts (`~/.claude/projects/**/*.jsonl`, subagent transcripts folded into their session), and pi's and omp's (`~/.pi/agent/sessions`, `~/.omp/agent/sessions`, pi's format version 3). `vai.local.opencode` reads OpenCode's per-session totals from its SQLite database (`~/.local/share/opencode/opencode.db`), as a module of its own since it links libsqlite3 (`sqlite-devel` or `libsqlite3-dev` at build time). Read defensively, since none of these formats is a public contract.
- **`anthropic`** (`anthropic/`) and **`openai`** (`openai/`): request encoding, response decoding, and stream-event decoding for each provider's actual wire format. A reasoning model's chain of thought comes back as `vai.Thinking` (and `.thinking_delta` on a stream) from either dialect: Anthropic's thinking blocks, or the `reasoning` / `reasoning_content` field OpenAI-compatible servers use. OpenAI-compatible streams ask for usage (`stream_options.include_usage`), which they otherwise don't send.
- **Transport** (`transport.v`, `transport_http.v`, `transport_curl.v`): the `Transport` interface, `NativeTransport` (`net.http`, non-streaming only), and `CurlTransport`, which shells out to `curl` for both request kinds and is what makes streaming work at all, since `net.http` has none. Handles the partial-line buffering across non-blocking reads itself, since `os.Process` doesn't give you a line-buffered read.
- **`Provider`** (`anthropic.Provider`, `openai.Provider`): `complete(req) !vai.Response` with retry (rate limiting, a momentary server failure, Anthropic's 529, respecting the server's own `Retry-After` header), and `stream(req) !chan vai.StreamEvent`, where a non-2xx answer or a curl failure (connection refused, a stalled stream) ends the stream with one `.error` event carrying the provider's message. `headers` adds or overrides request headers; every request names itself with `User-Agent: vai/<version>` unless told otherwise.

## Verified against

The test suite never sends traffic to a real endpoint: everything runs against fixtures and a local mock `net.http.Server`, including `complete()`'s retry path and `stream()` end-to-end through a real `curl` subprocess. Outside it, by hand, on 2026-10-20:

- **Ollama** (local), over both dialects (`/v1/chat/completions` and `/v1/messages`), with llama3.2 and with qwen3.8 as a reasoning model: text, thinking, usage, and its 402 for a cloud model the plan doesn't include.
- **z.AI GLM Coding Plan**, glm-5.3 and glm-5.3-flash over both dialects (`https://api.z.ai/api/coding/paas/v4`, `https://api.z.ai/api/anthropic`): text, thinking, usage, and a 401 for a bad key.
- **OpenCode Go**: its missing-session 400 and expired-key 401, on both dialects; no successful completion yet.
- **The `local` readers**: against this machine's real Claude Code transcripts, OpenCode database, and omp sessions, with totals equal to an independent count. pi's reader follows pi 1.3.0's source; no real pi session was available.

Never against Anthropic's or OpenAI's own API.

## What's not here yet

- **`Provider.count_tokens()`** and **`Provider.models()`**. Nothing calls either endpoint yet.
- **OpenAI-side tool use.** `tools` are sent, but `message.tool_calls` in the answer is not decoded yet: a tool-use reply arrives as empty content with `stop_reason: "tool_calls"`. Anthropic's `tool_use` blocks are decoded.
- **`stream()` doesn't retry.** `complete()` does; a streaming call that fails before or during the stream ends with an `.error` event, and retrying is the caller's call today.
- **Thinking signatures on a stream.** `complete()` keeps `Thinking.signature` so a thinking block can be sent back in a multi-turn tool-use conversation; `stream()` drops Anthropic's `signature_delta`, so a streamed thinking block can't be.
- **One merged usage event per stream.** Usage events are cumulative snapshots with only the fields the provider sent at that point (Anthropic: input and cache on `message_start`, output on `message_delta`); keep the last non-zero value of each field.

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

Same shape for any OpenAI-compatible endpoint, just point `base_url` at it:

```v
import vai
import vai.openai

p := openai.Provider{
	base_url: 'http://localhost:11434/v1' // Ollama
	// api_key: '...' // most local servers don't need one
}
resp := p.complete(vai.Request{
	model:    'qwen3.8:27b'
	messages: [vai.user('summarize this log')]
})!
for c in resp.content {
	match c {
		vai.Thinking { eprintln('[thinking] ${c.text}') }
		vai.TextContent { println(c.text) }
		else {}
	}
}
```

z.AI's GLM Coding Plan speaks both dialects; pick either provider:

```v
glm := openai.Provider{
	base_url: 'https://api.z.ai/api/coding/paas/v4'
	api_key:  os.getenv('ZAI_API_KEY')
}
// or, through the Anthropic-compatible endpoint:
glm_anthropic := anthropic.Provider{
	base_url: 'https://api.z.ai/api/anthropic'
	api_key:  os.getenv('ZAI_API_KEY')
}
resp := glm.complete(vai.Request{
	model:    'glm-5.3'
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
	match ev.kind {
		.content_delta { print(ev.text) }
		.thinking_delta { eprint(ev.text) }
		.error { eprintln('\nstream failed: ${ev.err}') } // e.g. "anthropic: HTTP 429: ..."
		else {}
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

`local.pi_sessions()`, `local.omp_sessions()` and `opencode.sessions()` (`import vai.local.opencode`) return the same `Session` shape. Subagents are folded into the session that started them, and `output_tokens` includes reasoning in all four, so totals compare across tools.

## Development

```sh
make check   # fmt-check + vet + test
make test
make fmt
```

`v test .` is slow once `net.http` is in the dependency graph (dozens of seconds), that's normal. If vai is also installed in `~/.vmodules`, the submodule tests import that copy instead of this tree; run them with an empty `VMODULES` (`VMODULES=$(mktemp -d) make check`). `local/opencode` needs the SQLite headers to build its tests.

## Scope

No tokenizer of its own: use `usage` from a response, or a provider's token-counting endpoint once `Provider.count_tokens()` exists. No abstraction that flattens Anthropic and OpenAI's real differences (thinking blocks, cache control, tool use) into a lowest common denominator, each provider submodule encodes and decodes its own shape. No agent loop, memory, or RAG: that's application scope, not a client library's.

## License

MIT
