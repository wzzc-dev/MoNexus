///|
/// Sliding-window failure budgets.
///
/// Pairing and authentication attempts are counted per scope and subject
/// before any secret comparison runs. The A1.0 spike had a single global
/// counter, which let one unauthenticated source lock out every other pairing;
/// the transport therefore enforces per-source **and** global budgets (and, for
/// authentication, a per-runtime budget as well).
///
/// The limiter is bounded: expired entries are pruned on every call, and when
/// the key table is full the least recently used key is evicted. Eviction can
/// only lose counts, never grant an attacker an unlimited fresh budget, because
/// the global scope is a single key that is never evicted while active.

///|
pub struct RateLimiter {
  entries : Map[String, Array[Int64]]
  now : () -> Int64
  window_ms : Int64
  max_keys : Int
}

///|
pub fn RateLimiter::new(
  now : () -> Int64,
  window_ms~ : Int64 = RATE_WINDOW_MS,
  max_keys~ : Int = MAX_RATE_KEYS,
) -> RateLimiter {
  { entries: Map([]), now, window_ms, max_keys }
}

///|
fn rate_key(scope : String, subject : String) -> String {
  scope + "|" + subject
}

///|
fn RateLimiter::prune_key(self : RateLimiter, key : String, now_ms : Int64) -> Unit {
  match self.entries.get(key) {
    Some(values) => {
      let cutoff = now_ms - self.window_ms
      let kept : Array[Int64] = []
      for value in values {
        if value > cutoff {
          kept.push(value)
        }
      }
      if kept.is_empty() {
        self.entries.remove(key)
      } else {
        self.entries.set(key, kept)
      }
    }
    None => ()
  }
}

///|
fn RateLimiter::prune_all(self : RateLimiter, now_ms : Int64) -> Unit {
  let keys = self.entries.keys().collect()
  for key in keys {
    self.prune_key(key, now_ms)
  }
}

///|
/// Evict the key whose most recent attempt is oldest. Called only when the
/// table is full and contains no expired keys, so an attacker cannot force
/// eviction of live budgets with a flood of one-shot keys in the same window
/// unless they also exceed `MAX_RATE_KEYS` distinct sources, at which point the
/// global scope still bounds the total.
fn RateLimiter::evict_oldest(self : RateLimiter) -> Unit {
  let mut oldest_key = ""
  let mut oldest_value = 0L
  let mut found = false
  for key, values in self.entries {
    let last = match values.get(values.length() - 1) {
      Some(value) => value
      None => 0L
    }
    if !found || last < oldest_value {
      found = true
      oldest_key = key
      oldest_value = last
    }
  }
  if found {
    self.entries.remove(oldest_key)
  }
}

///|
/// Consume one attempt from `scope` for `subject`. Returns `false` when the
/// budget for that scope is exhausted. The attempt is counted whether or not
/// the caller's secret later verifies.
pub fn RateLimiter::try_consume(
  self : RateLimiter,
  scope : String,
  subject : String,
  limit : Int,
) -> Bool {
  let now_ms = (self.now)()
  self.prune_all(now_ms)
  let key = rate_key(scope, subject)
  let values = match self.entries.get(key) {
    Some(existing) => existing
    None => {
      if self.entries.length() >= self.max_keys {
        self.evict_oldest()
      }
      let created : Array[Int64] = []
      self.entries.set(key, created)
      created
    }
  }
  if values.length() >= limit {
    return false
  }
  values.push(now_ms)
  true
}

///|
/// Number of attempts currently inside the window for a scope/subject. Test
/// and diagnostics only; it never bypasses the budget.
pub fn RateLimiter::attempts(self : RateLimiter, scope : String, subject : String) -> Int {
  match self.entries.get(rate_key(scope, subject)) {
    Some(values) => values.length()
    None => 0
  }
}
