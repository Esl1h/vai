// Package opencode reads OpenCode's session totals from its SQLite
// database into the same local.Session shape the other readers use. It
// is a module of its own, not part of vai.local, because reading SQLite
// links libsqlite3: a tool that only reads Claude Code, pi or omp
// sessions shouldn't need it.
//
// OpenCode keeps a per-session running total of tokens next to each
// session (session_v2, or session before OpenCode 2), and that total is
// what this reads: it is what OpenCode itself reports, and it includes
// calls that never become a stored message (titles, summaries), which
// summing the messages would miss. Like every reader here, it is read
// defensively: the schema is internal to OpenCode.
module opencode

import db.sqlite
import json2
import os
import time
import vai
import vai.local

// sessions reads $XDG_DATA_HOME/opencode/opencode.db, falling back to
// ~/.local/share like OpenCode does. Empty, not an error, when the
// database doesn't exist (OpenCode was never run here).
pub fn sessions() ![]local.Session {
	data_home := os.getenv_opt('XDG_DATA_HOME') or {
		os.join_path(os.home_dir(), '.local', 'share')
	}
	return sessions_from_db(os.join_path(data_home, 'opencode', 'opencode.db'))!
}

struct Row {
	id        string
	parent_id string
	project   string
	model     string
	usage     vai.Usage
	created   time.Time
	updated   time.Time
}

// sessions_from_db is sessions with the database path made explicit. The
// database is opened read-only, so a missing file is never created and
// a running OpenCode is never written to.
pub fn sessions_from_db(path string) ![]local.Session {
	if !os.exists(path) {
		return []local.Session{}
	}
	mut db := sqlite.connect_full(path, [.readonly], '')!
	defer {
		db.close() or {}
	}
	table := if db.q_int("select count(*) from sqlite_master where type = 'table' and name = 'session_v2'")! > 0 {
		'session_v2'
	} else {
		'session'
	}
	rows := db.exec("select id, coalesce(parent_id, ''), coalesce(directory, ''), coalesce(model, ''), tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_created, time_updated from ${table}")!

	mut by_id := map[string]Row{}
	mut order := []string{}
	for r in rows {
		if r.vals.len < 11 || r.vals[0] == '' {
			continue
		}
		by_id[r.vals[0]] = Row{
			id:        r.vals[0]
			parent_id: r.vals[1]
			project:   r.vals[2]
			model:     model_id(r.vals[3])
			// OpenCode counts reasoning apart from output; providers bill
			// it as output, and Claude Code's output_tokens already
			// include thinking, so it is folded in to keep Session
			// comparable across readers.
			usage:     vai.Usage{
				input_tokens:       r.vals[4].int()
				output_tokens:      r.vals[5].int() + r.vals[6].int()
				cache_read_tokens:  r.vals[7].int()
				cache_write_tokens: r.vals[8].int()
			}
			created:   time.unix_milli(r.vals[9].i64())
			updated:   time.unix_milli(r.vals[10].i64())
		}
		order << r.vals[0]
	}

	// A subagent runs as a child session (parent_id) whose tokens are not
	// in its parent's total, so it is folded into its root session, the
	// same as a Claude Code subagent transcript.
	mut out := []local.Session{}
	mut index := map[string]int{}
	for id in order {
		row := by_id[id]
		if row.parent_id != '' && root_of(by_id, id) != id {
			continue
		}
		index[id] = out.len
		out << local.Session{
			id:          row.id
			project_dir: row.project
			model:       row.model
			usage:       row.usage
			started_at:  row.created
			last_msg_at: row.updated
		}
	}
	for id in order {
		row := by_id[id]
		root := root_of(by_id, id)
		if root == id {
			continue
		}
		i := index[root] or { continue }
		mut s := out[i]
		s.usage = vai.Usage{
			input_tokens:       s.usage.input_tokens + row.usage.input_tokens
			output_tokens:      s.usage.output_tokens + row.usage.output_tokens
			cache_read_tokens:  s.usage.cache_read_tokens + row.usage.cache_read_tokens
			cache_write_tokens: s.usage.cache_write_tokens + row.usage.cache_write_tokens
		}
		if row.updated > s.last_msg_at {
			s.last_msg_at = row.updated
		}
		out[i] = s
	}
	return out
}

// root_of follows parent_id up to a session with no parent, or to the
// last one present: a child whose parent was deleted stands on its own.
// The step limit guards against a cycle in a corrupt database.
fn root_of(by_id map[string]Row, id string) string {
	mut cur := id
	for _ in 0 .. 64 {
		row := by_id[cur] or { return cur }
		if row.parent_id == '' || row.parent_id !in by_id {
			return cur
		}
		cur = row.parent_id
	}
	return cur
}

// model_id pulls the model id out of OpenCode's model column, a JSON
// object such as {"id":"glm-5.3","providerID":"zai-coding-plan"}.
// Anything else comes back as is.
fn model_id(raw string) string {
	val := json2.decode[json2.Any](raw) or { return raw }
	if val is map[string]json2.Any {
		if id := val['id'] {
			if id is string {
				return id
			}
		}
	}
	return raw
}
