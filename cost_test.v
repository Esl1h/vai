module vai

fn test_cost_known_model() {
	u := Usage{
		input_tokens:       1_000_000
		output_tokens:      1_000_000
		cache_write_tokens: 1_000_000
		cache_read_tokens:  1_000_000
	}
	c := cost('claude-sonnet-5', u)
	assert !c.unknown
	assert c.input == 2.00
	assert c.output == 10.00
	assert c.write == 2.50
	assert c.cached == 0.20
	assert c.total() == 14.70
}

fn test_cost_unknown_model() {
	c := cost('some-model-nobody-priced', Usage{ input_tokens: 100 })
	assert c.unknown
	assert c.total() == 0.0
}

fn test_price_book_override_does_not_affect_default() {
	mut pb := new_price_book()
	pb.set('my-local-model', ModelPrice{ input: 0.0, output: 0.0 })

	overridden := pb.cost('my-local-model', Usage{ input_tokens: 1_000_000 })
	assert !overridden.unknown
	assert overridden.total() == 0.0

	still_unknown := cost('my-local-model', Usage{ input_tokens: 1_000_000 })
	assert still_unknown.unknown
}
