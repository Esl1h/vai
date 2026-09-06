# vai

A [V](https://vlang.io) module: one request/response shape, streaming, cost accounting, and retry for Anthropic and OpenAI-compatible LLM APIs. "OpenAI-compatible" covers RouteLLM/Abacus, OpenRouter, Ollama, and LM Studio, since they all speak the same wire format behind a different `base_url`.

This exists because nothing like it does in V today: every tool that wants to call Claude or GPT from V currently hand-rolls JSON encoding, has no streaming story, and gets token cost wrong by skipping the cache-read/cache-write fields. `vai` is the shared foundation meant to sit under `ccstat`, `llmbench`, and `jaid`.

## Install

```sh
v install https://github.com/Esl1h/vai
```

## What's here

- **Core types** (`types.v`): `Message`, `Content` (a sum type: text, image, tool use, tool result, thinking), `Usage`, `Request`, `Response`, `StreamEvent`.
- **Cost accounting** (`cost.v`): a real, sourced pricing table for Anthropic's current models (Opus 5, Sonnet 5, Haiku 4.5, Claude Fable 5.1), all four token categories including cache write/read, and a `PriceBook` for adding or overriding prices without forking the module.
- **Retry** (`retry.v`): which HTTP statuses are worth retrying, and exponential backoff with jitter.
- **SSE framing** (`sse.v`): a provider-agnostic incremental parser (`SseParser.feed(line)`), because a transport reads a stream one line at a time, not as one complete body.
- **`local`** (`local/`): reads Claude Code's own session transcripts (`~/.claude/projects/**/*.jsonl`) for token usage, model, and timing — read defensively, since the format is undocumented and internal to the CLI.
- **`anthropic`** (`anthropic/`) and **`openai`** (`openai/`): request encoding, response decoding, and stream-event decoding for each provider's actual wire format. Each is tested against realistic fixtures, not live calls.
- **Transport** (`transport.v`, `transport_http.v`): the `Transport` interface, and `NativeTransport`, a `net.http`-based implementation for the non-streaming case.

## What's not here yet

- **`CurlTransport`** (streaming via a `curl -N` subprocess). `NativeTransport.post_stream` always returns an error: V's own `net.http` has no streaming response support, which was the biggest risk in this whole project and is now a confirmed fact, not a guess. A correct subprocess-based streaming reader needs its own care around partial-line buffering and hasn't been rushed in.
- **`Provider`** structs (`anthropic.Provider`, `openai.Provider`) that hold a `Transport` and expose `complete()`/`stream()`/`count_tokens()`. The encode/decode functions those would call already exist and are tested; the wiring isn't written yet.
- Any actual call to a live Anthropic or OpenAI-compatible endpoint. Every test here runs against a fixture or a local mock `net.http.Server` — this project follows the same rule as this author's other V projects: tests never send traffic to a real third-party endpoint.

## Usage (what works today)

```v
import vai
import vai.anthropic

req := vai.Request{
	model:      'claude-sonnet-5'
	messages:   [vai.user('summarize this log')]
	max_tokens: 1024
}
body := anthropic.encode_request(req)

// however the bytes come back (a real Transport, once one calls a live
// endpoint, isn't wired up yet):
resp := anthropic.decode_response(raw_json_response)!
println(resp.content)
println(vai.cost(resp.model, resp.usage).total())
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

`v test .` is slow once `net.http` is in the dependency graph (dozens of seconds) — that's normal.

## Scope

No tokenizer of its own: use `usage` from a response, or a provider's token-counting endpoint once `Provider` exists. No abstraction that flattens Anthropic and OpenAI's real differences (thinking blocks, cache control, tool use) into a lowest common denominator — each provider submodule encodes and decodes its own shape. No agent loop, memory, or RAG: that's application scope, not a client library's.

## License

MIT
