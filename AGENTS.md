# AGENTS.md

Instructions for coding agents working in this repository.

## What this project is

`vai` is a V module: one request/response shape, streaming, cost
accounting, and retry for Anthropic and OpenAI-compatible LLM APIs
(RouteLLM/Abacus, OpenRouter, Ollama, LM Studio all speak the OpenAI
shape). It is the foundation `ccstat`, `llmbench`, and `jaid` are meant to
be built on. `redact` and `vjsonrpc` are separate, dependency-free sibling
modules; `vai` does not depend on either.

## V is under-represented in your training data, verify, never guess

Same standing rule as `redact` and `vjsonrpc`. Compile after every
meaningful change: `v test .`. Check actual stdlib source before assuming a
signature:

```sh
grep -n "pub fn" ~/GIT/v/vlib/<module>/*.v
```

`v test .` on this repo is slow (dozens of seconds) once `net.http` is in
the dependency graph, that's normal, not a hang. If a run genuinely
hangs past a minute or two, or `v vet`/`v test` crashes with an internal
panic, clear V's build cache before assuming the code is wrong:

```sh
rm -rf /tmp/v_1000 ~/.cache/v
```

A `v vet` crash mid-session left a corrupted cache that hung every
subsequent `v test .` until this was cleared, the code itself was fine.

## Gotchas already found in this codebase, do not rediscover them

- **Never name a file `*_native.v`.** V's build system (`vlib/v/pref/should_compile.v`,
  `should_compile_c`) unconditionally excludes any file ending in
  `_native.v` from the normal C-backend build, it's reserved for V's own
  experimental native-codegen backend. The file still sits there, still
  looks fine, `v fmt`/`v vet` say nothing, and the compiler just silently
  drops every symbol in it, so the first sign of trouble is a confusing
  "unknown type" error in whatever file references it, a good hour was
  lost to this before finding the actual cause in the compiler source. The
  original design called the net.http transport file `transport_native.v`;
  it's `transport_http.v` here instead, specifically to avoid this. Don't
  rename it back, and don't reuse `_native.v` for any other file.
- **`is` narrows inside its own block; `.as_map()`/`.as_array()` do not
  compose with it.** `if x is map[string]json2.Any { x['key'] }` works ,
  `x` is a real map inside that block. But `if x is map[string]json2.Any {
  m := x.as_map() }` does not: `.as_map()` is a method on `Any`, and `x` is
  no longer statically `Any` inside the block, it's already the narrowed
  map. Either use `x` directly inside the block, or skip narrowing
  entirely and call `.as_map()`/`.as_array()` unconditionally (both are
  total functions per json2's own docs, safe on a value of the wrong
  shape, not just the right one).
- **`!is` as an early-return guard does not narrow the rest of the
  function; a compound `!is X || other_check` doesn't compile at all**
  (`other_check` can't see `X`'s fields because the checker never narrows
  across `||`). After a `if v !is T { return ... }` guard, `v` is still
  statically `Any`, call `.as_map()`/`.as_array()` explicitly, don't
  index `v` directly.
- Every bare JSON number decodes to `f64` (same finding as `vjsonrpc`).
  Anthropic's usage fields, OpenAI's usage fields, and stream deltas are
  read with an `is f64` check and `int(v)`. `v.int()` on an `f64` variant
  does truncate on V 0.5.2 (1.5 becomes 1) and returns `int` min for a
  value past 2^31, but it also returns 0 for a string, so it cannot tell
  a malformed field from a real zero; that is why the variant check
  exists, not because `.int()` ignores `f64`.
- **`json2.Any.str()` on a `Null` is the text `null`**, and on a number
  it is the formatted number. Reading a string field with `.str()` without
  an `is string` check turned OpenAI's `"content": null` (tool_calls
  answers, reasoning chunks) into a literal "null" text block. Check the
  variant first; `decode_stream_event`/`decode_response` in `openai/` do.
- `pub struct Foo { pub: ... }` fields are **read-only even from inside the
  same module**, building a struct up field-by-field (`sess.id = x`)
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
  before writing `local/`, `anthropic/`, `openai/`, don't assume this
  works in some other V version without re-checking.
- `net.http.Request.do()` needs a `mut req`; `Header.get_custom` takes a
  required second `HeaderQueryConfig{}` argument, it is not `@[params]`.
  `http.Server.close()` needs a `mut` local binding to the `&Server` the
  constructor returns, even though it's already a pointer.
- A left shift on a signed value (`i64(x) << n`) triggers a compiler
  notice about sign changes; cast to `u64` for the shift and convert back
  after, as `retry.v`'s `backoff_delay` does.
- **A bare `for { ... return ... }` with only conditional returns inside
  does not satisfy V's "missing return" check**, even when every reachable
  path logically returns, the checker won't prove that for you. Both
  `Provider.complete()` methods had to become a bounded
  `for attempt in 0 .. p.retry.max_attempts { ... }` followed by an
  unconditional `return error(...)` after the loop, instead of an infinite
  loop with an internal exhaustion check. Reach for a bounded loop plus a
  trailing return whenever a retry/poll loop needs to "give up after N".
- A struct field can be marked required with `@[required]` (e.g.
  `openai.Provider.base_url`) to force every literal to set it explicitly
 , used instead of a `base_url` default, since there's no sane default
  for an OpenAI-compatible endpoint the way there is for Anthropic's.
- `os.Process.stdout_read()` is non-blocking and returns `''` immediately
  when nothing is pending, it is not "wait for a line," it's "give me
  whatever's here right now, which may be empty, one line, half a line, or
  several lines." `CurlTransport.post_stream`'s `pump_curl_stdout` buffers
  across calls and only ever hands the SSE parser a complete line, polling
  with a short `time.sleep` between empty reads while `p.is_alive()`.
- **`CurlTransport` feeds the body through curl's stdin (`--data-binary
  @-`), never argv.** Linux caps one argv string at 128 KB (`MAX_ARG_STRLEN`);
  a bigger `-d body` made `execve` fail and surfaced as "curl produced no
  output". `os.Process` has no `stdin_close`, so `feed_body` closes
  `p.stdio_fd[0]` itself and marks it -1 so `Process.close()` skips it.
- `curl -w '\n%{http_code}'` is what gives `CurlTransport.post_json` the
  status code without a separate header-dump file: curl appends it after
  the body, and the response is split on the *last* newline.
- **When vai is VPM-installed on this machine (`~/.vmodules/vai`, which
  `toklen` needs), the `anthropic`/`openai`/`local` test files compile
  their `import vai` against that installed copy, not this working
  tree**, same resolution quirk as toklen's sibling-`vai` bug, other
  manifestation. The two copies going out of sync makes submodule tests
  fail with "no field named ..." / "no variant ..." on changes that are
  right here. To test root-module changes, point `VMODULES` at an empty
  directory for the run (`VMODULES=$(mktemp -d) make check`), so
  `import vai` resolves to this tree; CI has no installed copy and is
  not affected.

## Design decisions worth knowing before changing scope

- **Streaming is split into two concerns on purpose**: `SseParser` /
  `RawSseEvent` (in `sse.v`, provider-agnostic, just SSE framing) versus
  each provider's `decode_stream_event(RawSseEvent) ?vai.StreamEvent`
  (provider-specific: Anthropic's `content_block_delta`/`message_delta`
  shape vs. OpenAI's `choices[0].delta`/`[DONE]` sentinel shape). Don't
  collapse these; a transport should never need to know which provider
  it's talking to.
- **`Transport.post_stream` returns `RawSseEvent`, not `vai.StreamEvent`.**
  Turning raw SSE into a meaningful event is a provider's job.
  `Provider.stream()` chains `Transport.post_stream` through a provider's
  `decode_stream_event` via a small spawned pump function
  (`pump_anthropic_events`/`pump_openai_events`) that reads the raw
  channel and forwards only the events `decode_stream_event` recognizes
  onto a second channel it owns, closing that channel when the raw one
  closes. The same shape as `Provider.complete()` chaining
  `Transport.post_json` through `decode_response`, just with a goroutine
  in between instead of a direct call.
- **`Provider.complete()` retries internally and returns the final error
  as a plain V error, not an `RpcError`-style value.** It reads
  `HttpResponse.retry_after` and falls back to `retry.backoff_delay` when
  the server didn't send one. A caller that wants to distinguish "gave up
  after retries" from "not retryable at all" has to parse the error
  string, there's no typed error here yet. Revisit only if a downstream
  tool (`ccstat`, `llmbench`, `jaid`) actually needs that distinction.
- **`Provider.stream()` does not retry, but it does report failure.**
  `CurlTransport.post_stream` has curl write the HTTP status to stderr
  (`-w '%{stderr}...%{http_code}'`, read once curl exits), keeps the lines
  read before the first SSE event (where a JSON error body lands), and
  ends the channel with one synthetic `RawSseEvent` carrying `status` plus
  that body, or `err` for a curl failure (connection refused, a stall,
  exit code != 0). Each provider's pump turns it into one `.error` event
  worded like `complete()`'s errors. The `Transport` interface did not
  change; any other transport reports failure the same way, through
  those two fields, never through a heuristic in a provider.
- **`NativeTransport` sets `read_timeout`/`write_timeout` on every
  request (`timeout_secs`, default 300).** net.http's own default is 30 s
  per socket read, and a non-streaming completion on a slow local model
  sends nothing for longer than that, so the request timed out and
  `complete()` then retried the same slow request five times.
- **`NativeTransport.post_stream` always errors.** V's `net.http` has no
  streaming response support in this version; that was the single biggest
  risk called out before this module was written, and it's confirmed real,
  not assumed. `CurlTransport` is what actually streams, verified against
  a real `curl` subprocess talking to a local mock server, not just
  fixtures (see `transport_curl_test.v`,
  `anthropic/provider_stream_test.v`, `openai/provider_stream_test.v`).
- **Pricing is a plain `const` map, not an embedded JSON asset.** The
  original design considered `$embed_file('pricing.json')` plus an
  `$XDG_CONFIG_HOME` override; that's real complexity for marginal gain at
  this size. `PriceBook` (in `cost.v`) gives the same override capability
  (`pb.set(model, price)`) without it. Revisit only if the hardcoded table
  becomes genuinely hard to maintain across many providers.
- **Anthropic-only pricing table.** OpenAI-compatible targets (Abacus,
  OpenRouter, Ollama, LM Studio) have no single canonical price list ,
  `cost()` correctly reports `Cost{unknown: true}` for any of them rather
  than guessing. A caller wanting cost tracking for those must supply its
  own `PriceBook` entries.
- **`local.claude_sessions()` reads four `Usage` fields and ignores
  everything else** in `message.usage` (thinking-token breakdown, service
  tier, per-iteration detail, `server_tool_use`). Claude Code writes one
  line per content block of an assistant turn, each repeating the same
  `message.id` and the same usage object (a real transcript here had 1562
  usage lines for 924 distinct ids), so usage is counted once per
  `message.id`; the first version summed every line and roughly doubled
  every total. The schema is undocumented and internal to Claude Code;
  expect it to drift across CLI versions without notice, and re-verify
  against a real `~/.claude/projects/**/*.jsonl` file before trusting a
  schema change. Subagent transcripts (`<session>/subagents/*.jsonl`)
  carry the parent's sessionId and are merged into it; a `<synthetic>`
  model is Claude Code's placeholder and never becomes the session model.
- **`local.pi_sessions()`/`omp_sessions()`** read pi's session format
  version 3 (omp is a pi fork that kept it): assistant `message` usage plus
  the `usage`, `compaction` and `branch_summary` entries pi writes for its
  own summaries. Verified against omp 18.12 sessions and pi 1.3.0's source.
- **`vai.local.opencode` is its own module because it links libsqlite3**
  (`db.sqlite`, header needed at build time: `sqlite-devel` /
  `libsqlite3-dev`). It reads OpenCode's per-session totals
  (`session_v2`, or `session` before OpenCode 2), not the messages: the
  totals include calls never stored as messages and are what OpenCode
  reports. OpenCode counts reasoning apart from output, so it is added
  into `output_tokens`; child sessions (`parent_id`, subagents) are not in
  the parent's total and are folded into their root. Opened read-only.
  Never read the `credential`/`account` tables.

## Not yet implemented, do not assume these exist

- **Thinking-block signature in `stream()`**: `complete()`'s decode/encode
  round-trips `Thinking.signature` and `RedactedThinking.data` (required
  for multi-turn tool use; the API verifies them), but the streaming path
  cannot yet: Anthropic delivers the signature as a `signature_delta`
  inside a `content_block_delta` event, `StreamEvent` has no field to
  carry it, and `decode_stream_event` drops it. A *streamed* thinking
  block therefore still cannot be echoed back; fix `StreamEvent` first
  if a downstream tool needs streaming tool-use loops.

- **OpenAI `tool_calls` decoding.** `openai.encode_request` sends
  `tools`, but `decode_response` never reads `message.tool_calls`, so a
  tool-use answer comes back as empty content with
  `stop_reason: "tool_calls"`; `vai.ToolUse` only ever comes back from the
  Anthropic provider today.
- **`Provider.models()`, `Provider.count_tokens()`**. Neither endpoint is
  called from anywhere yet, nothing downstream has asked for them.
- **Usage events on a stream are cumulative snapshots, one per provider
  event that carries usage** (Anthropic: `message_start` with input and
  cache counts, `message_delta` with `output_tokens`). A caller pricing a
  stream keeps the last non-zero value per field; `vai` does not merge
  them into one event yet.
- **Tests never send traffic to a real endpoint**, on purpose, the same
  rule as `dnsbench`: everything in the suite runs against fixtures and a
  local mock `net.http.Server`. By hand, on 2026-10-20, `complete()` and
  `stream()` were run against a local Ollama (both dialects, with and
  without a reasoning model), z.AI's GLM Coding Plan
  (`https://api.z.ai/api/coding/paas/v4` and `https://api.z.ai/api/anthropic`,
  text, reasoning, usage and a 401), and OpenCode Go's error responses.
  Never against Anthropic's or OpenAI's own API.

## Build and test

```sh
make check   # fmt-check + vet + test
make test    # v test .
make fmt     # v fmt -w .
```

Always run `make check` before proposing a commit. Give it time, see the
slow-compile note above.

## Do not

- Add a tokenizer. Use `usage` from a response, or a provider's
  `count_tokens` endpoint, once `Provider.count_tokens()` exists.
- Flatten Anthropic's and OpenAI's differences (thinking blocks, cache
  control, tool use) into one shape. Each provider submodule exposes its
  own encode/decode; `vai`'s root types stay the common denominator, not a
  lowest-common-denominator abstraction that hides what's provider-specific.
- Build an agent loop, memory, or RAG here. That's application scope, not
  a client library's.
