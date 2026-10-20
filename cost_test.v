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

fn close(a f64, b f64) bool {
	d := a - b
	return d < 1e-9 && d > -1e-9
}

fn test_cost_5_5_models() {
	u := Usage{
		input_tokens:       1_000_000
		output_tokens:      1_000_000
		cache_write_tokens: 1_000_000
		cache_read_tokens:  1_000_000
	}
	opus := cost('claude-opus-5-5', u)
	assert close(opus.total(), 4.00 + 20.00 + 5.00 + 0.20)
	sonnet := cost('claude-sonnet-5-5', u)
	assert close(sonnet.cached, 0.10)
	assert close(sonnet.total(), 2.00 + 10.00 + 2.50 + 0.10)
}

fn test_cost_haiku_5_5_long_context_tier() {
	// The tier is the whole prompt: input plus cache write plus cache read.
	at_threshold := cost('claude-haiku-5-5', Usage{
		input_tokens:      40_000
		cache_read_tokens: 60_000
		output_tokens:     1_000_000
	})
	assert close(at_threshold.input, 0.004)
	assert close(at_threshold.cached, 0.0006)
	assert close(at_threshold.output, 0.50)

	over := cost('claude-haiku-5-5', Usage{
		input_tokens:      40_000
		cache_read_tokens: 60_001
		output_tokens:     1_000_000
	})
	assert close(over.input, 0.02)
	assert close(over.cached, 60_001.0 / 1_000_000.0 * 0.05)
	assert close(over.output, 2.50)
}
