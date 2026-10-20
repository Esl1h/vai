module vai

import time

fn test_retryable_status() {
	assert retryable_status(429)
	assert retryable_status(500)
	assert retryable_status(502)
	assert retryable_status(503)
	assert retryable_status(529)
	assert !retryable_status(400)
	assert !retryable_status(401)
	assert !retryable_status(404)
	assert !retryable_status(200)
}

fn test_backoff_delay_grows_and_is_capped() {
	p := RetryPolicy{
		base_delay: 100 * time.millisecond
		max_delay:  1 * time.second
	}
	d0 := p.backoff_delay(0)
	d5 := p.backoff_delay(5)
	// jitter can push d0 up to 1.5x base, so compare well past that.
	assert d0 >= 100 * time.millisecond
	assert d0 <= 200 * time.millisecond
	assert d5 <= 1500 * time.millisecond
	assert d5 <= p.max_delay * 3 / 2
}

fn test_backoff_delay_does_not_overflow_on_large_attempt() {
	p := RetryPolicy{
		base_delay: 100 * time.millisecond
		max_delay:  1 * time.second
	}
	d := p.backoff_delay(1000)
	assert d >= 0
	assert d <= p.max_delay * 3 / 2
}

fn test_parse_retry_after_valid() {
	d := parse_retry_after('30') or {
		assert false, 'expected a value'
		return
	}
	assert d == 30 * time.second
}

fn test_parse_retry_after_invalid_is_none() {
	if _ := parse_retry_after('not-a-number') {
		assert false, 'expected none'
	}
	if _ := parse_retry_after('0') {
		assert false, 'expected none for zero'
	}
	if _ := parse_retry_after('-5') {
		assert false, 'expected none for negative'
	}
}
