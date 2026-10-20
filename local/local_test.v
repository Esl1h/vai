module local

import os
import rand
import time

const fixture_session_1 = '{"type":"user","sessionId":"s1","cwd":"/home/esli/GIT/redact","timestamp":"2026-09-06T01:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
{"type":"assistant","sessionId":"s1","cwd":"/home/esli/GIT/redact","timestamp":"2026-09-06T01:00:05.000Z","message":{"id":"msg_a","role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"one"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":50,"output_tokens":30}}}
{"type":"assistant","sessionId":"s1","cwd":"/home/esli/GIT/redact","timestamp":"2026-09-06T01:00:06.000Z","message":{"id":"msg_a","role":"assistant","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"t1"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":50,"output_tokens":30}}}
{"type":"assistant","sessionId":"s1","cwd":"/home/esli/GIT/redact","timestamp":"2026-09-06T01:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":150,"output_tokens":40}}}
'

fn with_fixture(fn_ fn (root string) !) ! {
	root := os.join_path(os.temp_dir(), 'vai_local_test_${rand_suffix()}')
	proj := os.join_path(root, '-home-esli-GIT-redact')
	os.mkdir_all(proj)!
	defer {
		os.rmdir_all(root) or {}
	}
	os.write_file(os.join_path(proj, 'session1.jsonl'), fixture_session_1)!
	fn_(root)!
}

fn rand_suffix() string {
	return '${os.getpid()}_${rand.u32()}'
}

fn test_claude_sessions_from_root_parses_fixture() {
	// The fixture repeats msg_a on two lines (one per content block, the
	// way Claude Code writes them); its usage must be counted once.
	with_fixture(fn (root string) ! {
		sessions := claude_sessions_from_root(root)!
		assert sessions.len == 1
		s := sessions[0]
		assert s.id == 's1'
		assert s.project_dir == '/home/esli/GIT/redact'
		assert s.model == 'claude-sonnet-5'
		assert s.usage.input_tokens == 5
		assert s.usage.output_tokens == 70
		assert s.usage.cache_write_tokens == 100
		assert s.usage.cache_read_tokens == 200
	})!
}

fn test_claude_sessions_from_root_tracks_time_span() {
	with_fixture(fn (root string) ! {
		sessions := claude_sessions_from_root(root)!
		s := sessions[0]
		assert s.started_at.unix() < s.last_msg_at.unix()
	})!
}

fn test_claude_sessions_from_root_missing_dir_is_empty() {
	sessions := claude_sessions_from_root('/nonexistent/path/for/sure') or {
		assert false, 'expected no error, just an empty list'
		return
	}
	assert sessions.len == 0
}

fn test_parse_session_file_skips_unparseable_lines() {
	with_fixture(fn (root string) ! {
		proj := os.join_path(root, '-home-esli-GIT-redact')
		os.write_file(os.join_path(proj, 'garbage.jsonl'), 'not json at all\n')!
		sessions := claude_sessions_from_root(root)!
		// the garbage file has no sessionId anywhere, so it's dropped
		// entirely rather than producing a broken Session.
		assert sessions.len == 1
	})!
}

fn test_claude_sessions_ignore_synthetic_model() {
	with_fixture(fn (root string) ! {
		proj := os.join_path(root, '-home-esli-GIT-redact')
		os.write_file(os.join_path(proj, 'session2.jsonl'), '{"type":"assistant","sessionId":"s2","timestamp":"2026-09-06T02:00:00.000Z","message":{"id":"msg_b","role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"assistant","sessionId":"s2","timestamp":"2026-09-06T02:00:09.000Z","message":{"id":"msg_c","role":"assistant","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
')!
		sessions := claude_sessions_from_root(root)!
		s2 := sessions.filter(it.id == 's2')
		assert s2.len == 1
		assert s2[0].model == 'claude-opus-5-5'
	})!
}

fn test_claude_sessions_fold_subagents_into_parent() {
	with_fixture(fn (root string) ! {
		sub := os.join_path(root, '-home-esli-GIT-redact', 's1', 'subagents')
		os.mkdir_all(sub)!
		os.write_file(os.join_path(sub, 'agent-a1.jsonl'), '{"type":"assistant","sessionId":"s1","timestamp":"2026-09-06T01:05:00.000Z","message":{"id":"msg_sub","role":"assistant","model":"claude-haiku-5-5","usage":{"input_tokens":7,"output_tokens":9,"cache_creation_input_tokens":1,"cache_read_input_tokens":2}}}
')!
		sessions := claude_sessions_from_root(root)!
		assert sessions.len == 1
		s := sessions[0]
		assert s.model == 'claude-sonnet-5'
		assert s.usage.input_tokens == 5 + 7
		assert s.usage.output_tokens == 70 + 9
		assert s.usage.cache_write_tokens == 100 + 1
		assert s.usage.cache_read_tokens == 200 + 2
		assert s.last_msg_at.unix() == time.parse_rfc3339('2026-09-06T01:05:00.000Z')!.unix()
	})!
}
