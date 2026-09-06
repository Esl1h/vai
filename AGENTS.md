# AGENTS.md

Instructions for coding agents working in this repository.

## What this project is

`vai` is a V module: one request/response shape, streaming, cost
accounting, and retry for Anthropic and OpenAI-compatible LLM APIs
(RouteLLM/Abacus, OpenRouter, Ollama, LM Studio all speak the OpenAI
shape). It is the foundation `ccstat`, `llmbench`, and `jaid` are meant to
be built on. `redact` and `vjsonrpc` are separate, dependency-free sibling
modules; `vai` does not depend on either.

## V is under-represented in your training data — verify, never guess

Same standing rule as `redact` and `vjsonrpc`. Compile after every
meaningful change: `v test .`. Check actual stdlib source before assuming a
signature:

```sh
grep -n "pub fn" ~/GIT/v/vlib/<module>/*.v
```

`v test .` on this repo is slow (dozens of seconds) once `net.http` is in
the dependency graph — that's normal, not a hang. If a run genuinely
hangs past a minute or two, or `v vet`/`v test` crashes with an internal
panic, clear V's build cache before assuming the code is wrong:

```sh
rm -rf /tmp/v_1000 ~/.cache/v
```

A `v vet` crash mid-session left a corrupted cache that hung every
subsequent `v test .` until this was cleared — the code itself was fine.

## Gotchas already found in this codebase — do not rediscover them

- **Never name a file `*_native.v`.** V's build system (`vlib/v/pref/should_compile.v`,
  `should_compile_c`) unconditionally excludes any file ending in
  `_native.v` from the normal C-backend build — it's reserved for V's own
  experimental native-codegen backend. The file still sits there, still
  looks fine, `v fmt`/`v vet` say nothing, and the compiler just silently
  drops every symbol in it, so the first sign of trouble is a confusing
  "unknown type" error in whatever file references it — a good hour was
  lost to this before finding the actual cause in the compiler source. The
  original design called the net.http transport file `transport_native.v`;
  it's `transport_http.v` here instead, specifically to avoid this. Don't
  rename it back, and don't reuse `_native.v` for any other file.
- **`is` narrows inside its own block; `.as_map()`/`.as_array()` do not
  compose with it.** `if x is map[string]json2.Any { x['key'] }` works —
  `x` is a real map inside that block. But `if x is map[string]json2.Any {
  m := x.as_map() }` does not: `.as_map()` is a method on `Any`, and `x` is
  no longer statically `Any` inside the block, it's already the narrowed
  map. Either use `x` directly inside the block, or skip narrowing
  entirely and call `.as_map()`/`.as_array()` unconditionally (both are
  total functions per json2's own docs — safe on a value of the wrong
  shape, not just the right one).
- **`!is` as an early-return guard does not narrow the rest of the
  function; a compound `!is X || other_check` doesn't compile at all**
  (`other_check` can't see `X`'s fields because the checker never narrows
  across `||`). After a `if v !is T { return ... }` guard, `v` is still
  statically `Any` — call `.as_map()`/`.as_array()` explicitly, don't
  index `v` directly.
- Every bare JSON number decodes to `f64` (same finding as `vjsonrpc`).
  Anthropic's usage fields, OpenAI's usage fields, and stream deltas all
  need `int(v.f64())`, never `v.int()` (which only handles the `int`
  variant and silently returns 0 for everything else).
- `pub struct Foo { pub: ... }` fields are **read-only even from inside the
  same module** — building a struct up field-by-field (`sess.id = x`)
  needs `pub mut:`, not `pub:`. Preferred where possible: collect into
  local variables and construct the struct once at the end, which keeps
  the public type genuinely immutable to callers.
- `os.mkdir_all`/`os.write_file`/`os.rmdir_all` and a plain `map[string]T`
  (not just `json2.Any`) all follow the same map-indexing rules as
  `redact`/`vjsonrpc` found: `m[key]` without `or {}`/`in` on a sum-typed
  value returns the *first* listed variant's zero value, not an error and
  not `Null`.
- A project's own root module (the directory with `v.mod`, `name: 'vai'`)
  can be imported by its submodules as `import vai`, even pre-VPM-install,
  from a subdirectory like `local/` or `anthropic/`. Verified empirically
  before writing `local/`, `anthropic/`, `openai/` — don't assume this
  works in some other V version without re-checking.
- `net.http.Request.do()` needs a `mut req`; `Header.get_custom` takes a
  required second `HeaderQueryConfig{}` argument, it is not `@[params]`.
  `http.Server.close()` needs a `mut` local binding to the `&Server` the
  constructor returns, even though it's already a pointer.
- A left shift on a signed value (`i64(x) << n`) triggers a compiler
  notice about sign changes; cast to `u64` for the shift and convert back
  after, as `retry.v`'s `backoff_delay` does.

## Design decisions worth knowing before changing scope

- **Streaming is split into two concerns on purpose**: `SseParser` /
  `RawSseEvent` (in `sse.v`, provider-agnostic, just SSE framing) versus
  each provider's `decode_stream_event(RawSseEvent) ?vai.StreamEvent`
  (provider-specific: Anthropic's `content_block_delta`/`message_delta`
  shape vs. OpenAI's `choices[0].delta`/`[DONE]` sentinel shape). Don't
  collapse these; a transport should never need to know which provider
  it's talking to.
- **`Transport.post_stream` returns `RawSseEvent`, not `vai.StreamEvent`.**
  Turning raw SSE into a meaningful event is a provider's job. A
  `Provider.stream()` method (not yet written — see Not Yet Implemented)
  is what chains `Transport.post_stream` through a provider's
  `decode_stream_event`.
- **`NativeTransport.post_stream` always errors.** V's `net.http` has no
  streaming response support in this version; that was the single biggest
  risk called out before this module was written, and it's confirmed real,
  not assumed. `NativeTransport` covers `post_json` only. Do not attempt to
  fake streaming through it (e.g. polling `stop_receiving_limit` chunks) —
  wait for `CurlTransport`.
- **Pricing is a plain `const` map, not an embedded JSON asset.** The
  original design considered `$embed_file('pricing.json')` plus an
  `$XDG_CONFIG_HOME` override; that's real complexity for marginal gain at
  this size. `PriceBook` (in `cost.v`) gives the same override capability
  (`pb.set(model, price)`) without it. Revisit only if the hardcoded table
  becomes genuinely hard to maintain across many providers.
- **Anthropic-only pricing table.** OpenAI-compatible targets (Abacus,
  OpenRouter, Ollama, LM Studio) have no single canonical price list —
  `cost()` correctly reports `Cost{unknown: true}` for any of them rather
  than guessing. A caller wanting cost tracking for those must supply its
  own `PriceBook` entries.
- **`local.claude_sessions()` reads four `Usage` fields and ignores
  everything else** in `message.usage` (thinking-token breakdown, service
  tier, per-iteration detail, `server_tool_use`) — confirmed against real
  session files on the machine this was built on, not guessed. The schema
  is undocumented and internal to Claude Code; expect it to drift across
  CLI versions without notice, and re-verify against a real
  `~/.claude/projects/**/*.jsonl` file before trusting a schema change.

## Not yet implemented — do not assume these exist

- **`CurlTransport`** (streaming via `curl -N` in a subprocess). This was
  deliberately deferred rather than rushed: `os.Process` in this V version
  has no line-buffered stdout read, only `stdout_read()` (whatever's
  currently available) and `stdout_slurp()` (blocks for the whole output).
  A correct implementation needs its own partial-line buffering across
  reads, tested against a real subprocess before it's trusted — don't
  improvise this into an unrelated commit.
- **`anthropic.Provider` / `openai.Provider`** (the structs that hold a
  `Transport` + config and implement `complete()`/`stream()`/`models()`/
  `count_tokens()`). Only the pure encode/decode functions exist so far
  (`encode_request`, `decode_response`, `decode_stream_event` in both
  submodules) — they're fully tested against fixtures, but nothing wires
  them to a `Transport` yet.
- No live call to a real Anthropic or OpenAI-compatible endpoint has been
  made from this codebase. Everything is verified against fixtures and a
  local mock `net.http.Server` (see `transport_http_test.v`), on purpose
  — this project follows the same rule as `dnsbench`: tests never send
  traffic to a real third-party endpoint.

## Build and test

```sh
make check   # fmt-check + vet + test
make test    # v test .
make fmt     # v fmt -w .
```

Always run `make check` before proposing a commit. Give it time — see the
slow-compile note above.

## Do not

- Add a tokenizer. Use `usage` from a response, or a provider's
  `count_tokens` endpoint, once `Provider` exists.
- Flatten Anthropic's and OpenAI's differences (thinking blocks, cache
  control, tool use) into one shape. Each provider submodule exposes its
  own encode/decode; `vai`'s root types stay the common denominator, not a
  lowest-common-denominator abstraction that hides what's provider-specific.
- Build an agent loop, memory, or RAG here. That's application scope, not
  a client library's.
