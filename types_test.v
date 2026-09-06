module vai

fn test_user_and_assistant_helpers() {
	m := user('hi')
	assert m.role == .user
	assert m.content.len == 1
	content := m.content[0]
	if content is TextContent {
		assert content.text == 'hi'
	} else {
		assert false, 'expected TextContent'
	}
}

fn test_usage_total_tokens() {
	u := Usage{
		input_tokens: 10
		output_tokens: 5
		cache_write_tokens: 2
		cache_read_tokens: 3
	}
	assert u.total_tokens() == 20
}
