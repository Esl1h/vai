module opencode

import db.sqlite
import os
import rand

// The columns OpenCode 2's session_v2 has that this reader touches; the
// real table has many more.
const schema = 'create table session_v2 (id text primary key, parent_id text, directory text, model text, tokens_input integer, tokens_output integer, tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer, time_created integer, time_updated integer)'

fn with_db(statements []string, f fn (path string) !) ! {
	path := os.join_path(os.temp_dir(), 'vai_opencode_test_${os.getpid()}_${rand.u32()}.db')
	defer {
		os.rm(path) or {}
	}
	mut db := sqlite.connect(path)!
	for s in statements {
		db.exec_none(s)
	}
	db.close()!
	f(path)!
}

fn test_sessions_from_db_folds_subagents_into_root() {
	with_db([
		schema,
		'insert into session_v2 values (\'ses_root\', null, \'/home/esli/GIT/vai\', \'{"id":"glm-5.3","providerID":"zai-coding-plan","variant":"max"}\', 100, 10, 5, 1000, 0, 1792441697697, 1792441800000)',
		'insert into session_v2 values (\'ses_child\', \'ses_root\', \'/home/esli/GIT/vai\', \'{"id":"glm-5.3-flash","providerID":"zai-coding-plan"}\', 20, 2, 0, 300, 7, 1792441700000, 1792441900000)',
		'insert into session_v2 values (\'ses_grandchild\', \'ses_child\', \'/home/esli/GIT/vai\', \'{"id":"glm-5.3-flash","providerID":"zai-coding-plan"}\', 3, 1, 0, 0, 0, 1792441710000, 1792441720000)',
		'insert into session_v2 values (\'ses_other\', null, \'/tmp\', \'{"id":"qwen3.8-flash","providerID":"opencode-go"}\', 1, 1, 0, 0, 0, 1792441000000, 1792441001000)',
	], fn (path string) ! {
		sessions := sessions_from_db(path)!
		assert sessions.len == 2
		root := sessions.filter(it.id == 'ses_root')[0]
		assert root.model == 'glm-5.3'
		assert root.project_dir == '/home/esli/GIT/vai'
		assert root.usage.input_tokens == 100 + 20 + 3
		// reasoning (5) counts as output
		assert root.usage.output_tokens == 10 + 5 + 2 + 1
		assert root.usage.cache_read_tokens == 1000 + 300
		assert root.usage.cache_write_tokens == 7
		assert root.started_at.unix_milli() == 1792441697697
		assert root.last_msg_at.unix_milli() == 1792441900000
		other := sessions.filter(it.id == 'ses_other')[0]
		assert other.model == 'qwen3.8-flash'
	})!
}

fn test_sessions_from_db_reads_pre_v2_table() {
	with_db([
		schema.replace('session_v2', 'session'),
		'insert into session values (\'ses_old\', null, \'/tmp\', \'{"id":"glm-5.3-flash","providerID":"opencode-go"}\', 7, 3, 0, 0, 0, 1790000000000, 1790000001000)',
	], fn (path string) ! {
		sessions := sessions_from_db(path)!
		assert sessions.len == 1
		assert sessions[0].id == 'ses_old'
		assert sessions[0].usage.input_tokens == 7
	})!
}

fn test_sessions_from_db_missing_file_is_empty_and_not_created() {
	path := os.join_path(os.temp_dir(), 'vai_opencode_missing_${os.getpid()}_${rand.u32()}.db')
	sessions := sessions_from_db(path)!
	assert sessions.len == 0
	assert !os.exists(path)
}

fn test_model_id() {
	assert model_id('{"id":"glm-5.3","providerID":"zai-coding-plan"}') == 'glm-5.3'
	assert model_id('') == ''
	assert model_id('not json') == 'not json'
}
