# vai

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
- **`local`** (`local/`): reads Claude Code's own session transcripts (`~/.claude/projects/**/*.jsonl`) for token usage, model, and timing, read defensively, since the format is undocumented and internal to the CLI.
- **`anthropic`** (`anthropic/`) and **`openai`** (`openai/`): request encoding, response decoding, and stream-event decoding for each provider's actual wire format. Each is tested against realistic fixtures, not live calls.
- **Transport** (`transport.v`, `transport_http.v`, `transport_curl.v`): the `Transport` interface, `NativeTransport` (`net.http`, non-streaming only), and `CurlTransport`, which shells out to `curl` for both request kinds and is what makes streaming work at all, since `net.http` has none. Handles the partial-line buffering across non-blocking reads itself, since `os.Process` doesn't give you a line-buffered read.
- **`Provider`** (`anthropic.Provider`, `openai.Provider`): `complete(req) !vai.Response` with retry (rate limiting, a momentary server failure, Anthropic's 529, respecting the server's own `Retry-After` header), and `stream(req) !chan vai.StreamEvent`. Both tested against a local mock server, `complete()`'s retry path with a fake 429-then-succeed handler, `stream()` end-to-end through a real `curl` subprocess parsing a real SSE body.

## What's not here yet

- **`Provider.count_tokens()`** and **`Provider.models()`**. Nothing calls either endpoint yet.
- **`stream()` doesn't see the HTTP status of the request.** `Transport.post_stream` returns only a channel, no status code, so a non-2xx error response (e.g. a 429 JSON body instead of an event stream) gets its body fed to the SSE parser like any other line and most likely produces zero events rather than a clear error. `complete()` doesn't have this problem. Fixing it needs a `Transport` interface change that hasn't been made.
- **`stream()` doesn't retry.** `complete()` does; a streaming call that fails before or during the stream is the caller's problem to retry today.
- Any actual call to a live Anthropic or OpenAI-compatible endpoint. Every test here runs against a fixture or a local mock `net.http.Server`, this project follows the same rule as this author's other V projects: tests never send traffic to a real third-party endpoint. `complete()` and `stream()` are wired and tested against a mock, but neither has been run against the real API yet.

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
