// Package local reads session state that Claude Code and OpenCode already
// keep on disk, so a tool built on vai doesn't have to reverse-engineer
// that format itself. The format is undocumented, internal, and changes
// between CLI versions without notice: every field here is read
// defensively, and a line or file that doesn't parse is skipped rather
// than failing the whole read.
module local

import json2
import os
import time
import vai

pub struct Session {
pub mut:
	id          string
	project_dir string
	model       string
	usage       vai.Usage
	started_at  time.Time
	last_msg_at time.Time
}

// claude_sessions reads every session transcript under
// ~/.claude/projects/**/*.jsonl. Returns an empty list, not an error, when
// the directory doesn't exist (e.g. Claude Code was never run here).
pub fn claude_sessions() ![]Session {
	root := os.join_path(os.home_dir(), '.claude', 'projects')
	return claude_sessions_from_root(root)!
}

// claude_sessions_from_root is claude_sessions with the root directory
// made explicit, mainly so tests don't have to touch a real home directory.
pub fn claude_sessions_from_root(root string) ![]Session {
	if !os.exists(root) {
		return []Session{}
	}
	// A subagent's transcript is a file of its own under
	// <session>/subagents/, but it carries the parent's sessionId and its
	// tokens are part of what that session cost, so it is folded into the
	// parent rather than listed as another session with the same id. Main
	// transcripts go first so model and project come from the parent.
	mut main_files := []string{}
	mut subagent_files := []string{}
	subagents_dir := '${os.path_separator}subagents${os.path_separator}'
	for f in find_jsonl_files(root)! {
		if f.contains(subagents_dir) {
			subagent_files << f
		} else {
			main_files << f
		}
	}
	mut sessions := []Session{}
	mut index := map[string]int{}
	for f in main_files {
		s := parse_session_file(f) or { continue }
		add_session(mut sessions, mut index, s)
	}
	for f in subagent_files {
		s := parse_session_file(f) or { continue }
		add_session(mut sessions, mut index, s)
	}
	return sessions
}

// add_session appends s, or merges it into the session already listed
// under the same id: usage adds up, the time span widens, and model and
// project are only filled in where the earlier file had none.
fn add_session(mut sessions []Session, mut index map[string]int, s Session) {
	i := index[s.id] or {
		index[s.id] = sessions.len
		sessions << s
		return
	}
	mut cur := sessions[i]
	cur.usage = vai.Usage{
		input_tokens:       cur.usage.input_tokens + s.usage.input_tokens
		output_tokens:      cur.usage.output_tokens + s.usage.output_tokens
		cache_write_tokens: cur.usage.cache_write_tokens + s.usage.cache_write_tokens
		cache_read_tokens:  cur.usage.cache_read_tokens + s.usage.cache_read_tokens
	}
	if s.started_at.unix() != 0 && (cur.started_at.unix() == 0 || s.started_at < cur.started_at) {
		cur.started_at = s.started_at
	}
	if s.last_msg_at > cur.last_msg_at {
		cur.last_msg_at = s.last_msg_at
	}
	if cur.model == '' {
		cur.model = s.model
	}
	if cur.project_dir == '' {
		cur.project_dir = s.project_dir
	}
	sessions[i] = cur
}

fn find_jsonl_files(dir string) ![]string {
	mut out := []string{}
	for entry in os.ls(dir)! {
		full := os.join_path(dir, entry)
		if os.is_dir(full) {
			out << find_jsonl_files(full)!
		} else if full.ends_with('.jsonl') {
			out << full
		}
	}
	return out
}

// synthetic_model is what Claude Code puts in "model" on messages it
// writes itself (an interrupted turn, an API error shown inline). Taken
// as the session's model, it hid the real one whenever it came last.
const synthetic_model = '<synthetic>'

fn parse_session_file(path string) !Session {
	lines := os.read_lines(path)!

	mut sess := Session{}
	mut usage := vai.Usage{}
	mut seen_any_timestamp := false
	// Claude Code writes one line per content block of an assistant turn,
	// each repeating the same message.id and the same usage object, so a
	// plain sum roughly doubles every count (a real transcript on this
	// machine had 1562 usage lines for 924 distinct ids). Count each
	// message id once.
	mut seen_message_ids := map[string]bool{}

	for line in lines {
		if line.trim_space() == '' {
			continue
		}
		val := json2.decode[json2.Any](line) or { continue }
		if val !is map[string]json2.Any {
			continue
		}
		obj := val.as_map()

		if sess.id == '' {
			if v := obj['sessionId'] {
				sess.id = v.str()
			}
		}
		if sess.project_dir == '' {
			if v := obj['cwd'] {
				sess.project_dir = v.str()
			}
		}

		if ts_val := obj['timestamp'] {
			ts := time.parse_rfc3339(ts_val.str()) or { continue }
			if !seen_any_timestamp || ts < sess.started_at {
				sess.started_at = ts
			}
			if !seen_any_timestamp || ts > sess.last_msg_at {
				sess.last_msg_at = ts
			}
			seen_any_timestamp = true
		}

		msg_val := obj['message'] or { continue }
		if msg_val !is map[string]json2.Any {
			continue
		}
		msg := msg_val.as_map()

		if model_val := msg['model'] {
			model := model_val.str()
			if model != synthetic_model {
				sess.model = model
			}
		}
		if usage_val := msg['usage'] {
			if id_val := msg['id'] {
				if id_val is string {
					if id_val in seen_message_ids {
						continue
					}
					seen_message_ids[id_val] = true
				}
			}
			accumulate_usage(mut usage, usage_val.as_map())
		}
	}

	if sess.id == '' {
		return error('no sessionId found in ${path}')
	}
	sess.usage = usage
	return sess
}

// accumulate_usage adds one message's usage onto a session running total.
// Only the four fields vai.Usage tracks are read; the rest of what Claude
// Code writes (thinking token breakdown, service tier, per-iteration
// detail) isn't something a cost/context tool needs.
fn accumulate_usage(mut usage vai.Usage, obj map[string]json2.Any) {
	if v := obj['input_tokens'] {
		usage.input_tokens += int(v.f64())
	}
	if v := obj['output_tokens'] {
		usage.output_tokens += int(v.f64())
	}
	if v := obj['cache_creation_input_tokens'] {
		usage.cache_write_tokens += int(v.f64())
	}
	if v := obj['cache_read_input_tokens'] {
		usage.cache_read_tokens += int(v.f64())
	}
}
