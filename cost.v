module vai

// ModelPrice is USD per 1,000,000 tokens in each category.
pub struct ModelPrice {
pub:
	input       f64
	output      f64
	cache_write f64
	cache_read  f64
	// long_context, when its `over` is set, replaces the four prices above
	// for a request whose prompt (input, cache write and cache read tokens
	// together) is over that many tokens. Only Claude Haiku 5.5 is priced
	// this way.
	long_context LongContextPrice
}

// LongContextPrice is a model's price for long prompts, USD per 1,000,000
// tokens. The tier is decided per request, so pricing a Usage summed over
// several requests can pick the wrong one.
pub struct LongContextPrice {
pub:
	over        int
	input       f64
	output      f64
	cache_write f64
	cache_read  f64
}

pub struct Cost {
pub:
	input   f64
	output  f64
	write   f64
	cached  f64
	unknown bool
}

// total sums every category. Meaningless when unknown is true.
pub fn (c Cost) total() f64 {
	return c.input + c.output + c.write + c.cached
}

const tokens_per_unit = 1_000_000.0

// default_pricing covers Anthropic's first-party models, from
// platform.claude.com/docs/en/about-claude/pricing as of 2026-10-20.
// cache_write is the 5-minute-TTL rate (1.25x input); cache_read is 0.1x
// input, except Claude Opus 5.5 and Sonnet 5.5 (0.05x) and Claude Fable 5.1
// (0.025x). A model not listed here is not unsupported, it just isn't
// priced: cost() reports Cost{unknown: true} rather than silently
// returning zero.
const default_pricing = {
	'claude-opus-5-5':   ModelPrice{
		input:       4.00
		output:      20.00
		cache_write: 5.00
		cache_read:  0.20
	}
	'claude-sonnet-5-5': ModelPrice{
		input:       2.00
		output:      10.00
		cache_write: 2.50
		cache_read:  0.10
	}
	'claude-haiku-5-5':  ModelPrice{
		input:        0.10
		output:       0.50
		cache_write:  0.125
		cache_read:   0.01
		long_context: LongContextPrice{
			over:        100_000
			input:       0.50
			output:      2.50
			cache_write: 0.625
			cache_read:  0.05
		}
	}
	'claude-opus-5':     ModelPrice{
		input:       5.00
		output:      25.00
		cache_write: 6.25
		cache_read:  0.50
	}
	'claude-sonnet-5':   ModelPrice{
		input:       2.00
		output:      10.00
		cache_write: 2.50
		cache_read:  0.20
	}
	'claude-haiku-4-5':  ModelPrice{
		input:       1.00
		output:      5.00
		cache_write: 1.25
		cache_read:  0.10
	}
	'claude-fable-5-1':  ModelPrice{
		input:       10.00
		output:      50.00
		cache_write: 12.50
		cache_read:  0.25
	}
}

// PriceBook lets a caller override or add prices without forking vai: a
// price list changes far more often than a library release does.
pub struct PriceBook {
mut:
	prices map[string]ModelPrice
}

// new_price_book starts from a copy of the built-in table.
pub fn new_price_book() PriceBook {
	return PriceBook{
		prices: default_pricing.clone()
	}
}

// set adds a model or overrides an existing price.
pub fn (mut pb PriceBook) set(model string, price ModelPrice) {
	pb.prices[model] = price
}

// cost prices usage against this book's table, including any overrides.
pub fn (pb PriceBook) cost(model string, u Usage) Cost {
	price := pb.prices[model] or { return Cost{ unknown: true } }
	return price_usage(price, u)
}

fn price_usage(price ModelPrice, u Usage) Cost {
	lc := price.long_context
	prompt := u.input_tokens + u.cache_write_tokens + u.cache_read_tokens
	p := if lc.over > 0 && prompt > lc.over {
		ModelPrice{
			input:       lc.input
			output:      lc.output
			cache_write: lc.cache_write
			cache_read:  lc.cache_read
		}
	} else {
		price
	}
	return Cost{
		input:  f64(u.input_tokens) / tokens_per_unit * p.input
		output: f64(u.output_tokens) / tokens_per_unit * p.output
		write:  f64(u.cache_write_tokens) / tokens_per_unit * p.cache_write
		cached: f64(u.cache_read_tokens) / tokens_per_unit * p.cache_read
	}
}

// cost prices one request's usage against the built-in table, for the
// common case that doesn't need PriceBook's override support.
pub fn cost(model string, u Usage) Cost {
	price := default_pricing[model] or { return Cost{ unknown: true } }
	return price_usage(price, u)
}
