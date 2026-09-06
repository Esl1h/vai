module vai

import rand
import time

// retryable_status reports whether an HTTP status is worth retrying: rate
// limiting, a momentary server failure, or Anthropic's 529 (overloaded).
// Any other 4xx means the request itself is wrong; retrying won't help.
pub fn retryable_status(code int) bool {
	return code == 429 || code == 500 || code == 502 || code == 503 || code == 529
}

pub struct RetryPolicy {
pub:
	max_attempts int = 5
	base_delay   time.Duration = 500 * time.millisecond
	max_delay    time.Duration = 30 * time.second
}

// backoff_delay returns exponential backoff with up to 50% jitter for the
// given zero-based attempt number, capped at max_delay.
pub fn (p RetryPolicy) backoff_delay(attempt int) time.Duration {
	// Cap the shift so a large attempt count can't overflow into a
	// negative or wrapped duration before the max_delay clamp runs.
	shift := if attempt > 20 { u32(20) } else { u32(attempt) }
	mut delay := time.Duration(u64(p.base_delay) << shift)
	if delay > p.max_delay {
		delay = p.max_delay
	}
	jitter := i64(f64(delay) * 0.5 * rand.f64())
	return delay + time.Duration(jitter)
}

// parse_retry_after reads a Retry-After header's seconds form. The
// HTTP-date form exists in the spec, but no provider vai targets sends it.
pub fn parse_retry_after(header string) ?time.Duration {
	secs := header.trim_space().int()
	if secs <= 0 {
		return none
	}
	return time.Duration(secs) * time.second
}
