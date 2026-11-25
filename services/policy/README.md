# monexus/policy — A1.3 policy core

Risk classification and approval binding for the paired remote runtime
(ADR-0012 §4/§5). This package is a pure library: it does not execute
anything, open sockets, or create approval Decisions. The primary remains the
sole approval authority; the runtime only *verifies* grants the primary
issued.

## Public API

| Area | API |
| --- | --- |
| Operations | `PolicyOperation` (`exec`, `pty`, `fs.read`, `fs.write`, `fs.delete`, `git.read`, `git.write`, `Unknown`) |
| Requests | `ExecutionRequest::new`, `::canonical`, `::digest`, `::validate` |
| Paths | `normalize_abs_path`, `path_within_root` |
| Snapshots | `PolicyRules::new`, `PolicySnapshot::new`, `::encode`, `::decode`, `::decode_pinned`, `::is_fresh`, `::hash_matches` |
| Policy source | `PolicySource`, `PolicyContext::with_snapshot` / `::missing` / `::invalid` |
| Decisions | `evaluate`, `PolicyDecision`, `DecisionKind`, `::verdict`, `::encode` |
| Grants | `ApprovalGrant::new` / `::encode` / `::decode`, `verify_grant`, `verify_and_consume`, `verify_grant_for_request`, `verify_and_consume_for_request`, `GrantError` |
| Nonce memory | `ConsumedNonces` |

## Command digest

`ExecutionRequest::digest()` is `sha256:` followed by the lowercase hex
SHA-256 of the canonical serialization below. It depends only on the argv
array (order preserved), the absolute cwd, the workspace root, the operation
label, and the sorted, de-duplicated environment variable **names**. It never
includes a run id, policy version, timestamp, or environment value.

```text
monexus.exec.v1\n
{"argv":["git","status","--porcelain"],"cwd":"/home/user/ws","env":["LANG","PATH"],"operation":"exec","workspace_root":"/home/user/ws"}
```

Known vector (pinned by `digest_test.mbt`):

```text
sha256:296305004bbb2b00ac43a41ad139de7a89f86d78a4552f3167f56cc43da0cd25
```

The canonical serializer is locale-independent: fixed key order, JSON string
escaping with lowercase `\u00xx` for control characters, plain decimal
integers. The digest is therefore stable across processes on the same
platform, which lets the primary bind a grant to exactly one command.

## Snapshot format

```json
{
  "expires_at_ms": 1764003600000,
  "format": "monexus.policy.snapshot",
  "format_version": 1,
  "hash": "<64 lowercase hex>",
  "issued_at_ms": 1764000000000,
  "rules": {
    "allow_read_only": true,
    "allowed_argv_prefixes": ["moon test"],
    "allowed_operations": ["fs.write"],
    "denied_operations": ["git.write"],
    "denied_patterns": ["curl | sh"],
    "env_allowlist": ["HOME", "LANG", "PATH"],
    "high_risk_operations": ["pty"],
    "high_risk_patterns": []
  },
  "version": "pol-1"
}
```

The content hash is the SHA-256 of the canonical body (everything above except
`hash`) with the domain prefix `monexus.policy.snapshot.v1\n`. All rule arrays
are sorted and de-duplicated before hashing, so rule order in input does not
change the hash. `decode` is strict: unknown top-level or rule keys, unknown
`format`/`format_version`, malformed hex, wrong types, inverted time ranges,
and a recomputed hash that does not match the embedded `hash` are all
rejected. There is no default-allow fallback: a rejected snapshot yields
`Missing`/`Invalid` and every non-built-in-local decision becomes
`Unverifiable`.

`decode_pinned(text, expected_hash)` additionally checks the hash the caller
pinned out of band (the primary's authenticated snapshot announcement).

## Evaluation order

`evaluate(context, request)` returns exactly one of `Allow`,
`ApprovalRequired`, `Deny`, `Unverifiable`:

1. Malformed request (empty argv for exec/pty, limits, invalid env names,
   relative paths, cwd/argv paths escaping the workspace root) → `Deny`.
2. Built-in catastrophic commands (`mkfs*`, `shutdown`, `systemctl`, disk
   partitioning, fork bombs, writes to `/dev/sd*`, …) → `Deny`.
3. `Missing`/`Invalid` snapshot → `Unverifiable` (never `Allow`).
4. Env name not in `env_allowlist` → `Deny` (an empty allowlist permits no
   names).
5. Snapshot `denied_operations` / `denied_patterns` → `Deny`.
6. High-risk (built-in or snapshot-marked): `ApprovalRequired` when the
   snapshot is fresh and the primary is reachable; otherwise `Unverifiable`
   with "stale" or "unreachable".
7. Read-only built-in command (`ls`, `cat`, `git status`, `fs.read`,
   `git.read`, …) when `allow_read_only` is set → `Allow` with the policy
   version, even while offline/stale.
8. Operation in `allowed_operations` or argv matching an
   `allowed_argv_prefixes` entry → `Allow` while fresh and reachable;
   otherwise `Unverifiable`.
9. Anything else → `ApprovalRequired` while fresh and reachable; otherwise
   `Unverifiable`.

High-risk categories per ADR-0012: installers, host mounts and containers,
delete/destructive operations, privilege elevation, arbitrary `sh -c`-style
execution, and anything the snapshot marks high-risk. `Unknown` operations
and unlisted operations never fall through to `Allow`.

## Offline semantics

* Primary unreachable + high-risk or unknown → `Unverifiable`; the caller
  must wait. Never execute.
* Low-risk read-only permitted by a fresh snapshot may run locally, and the
  decision reports the policy version and hash.
* Medium-risk snapshot-allowed work requires both a fresh snapshot and a
  reachable primary.

## Approval grants

A grant is created only by the primary after the owner answers a Decision.
This package verifies the grant and returns typed errors; it never creates a
Decision. Verification order (first failure wins):

1. structural validity → `MalformedGrant`
2. run id binding → `RunMismatch`
3. command digest binding → `DigestMismatch`
4. policy availability → `PolicyUnavailable`
5. policy version binding → `PolicyVersionMismatch`
6. snapshot freshness → `PolicyStale`
7. `now > expires_at_ms` → `Expired`
8. issue time beyond clock skew → `NotYetValid`
9. lifetime over `MAX_GRANT_TTL_MS` (10 minutes) → `TtlTooLong`

`verify_and_consume` then records the nonce and returns `ReplayedNonce` if it
was already seen. A failed verification never consumes the nonce, so a
corrected retry still works.

### Nonce persistence and restart semantics

`ConsumedNonces` is a bounded in-memory map (default capacity 1024). Entries
are pruned once the grant expires, and at capacity the earliest-expiring
entry is evicted. **A process restart forgets consumed nonces.** A grant that
has not yet expired could therefore be presented again after a restart; the
exposure is bounded by the ten-minute maximum grant lifetime and should be
closed at the exec boundary by the run-id idempotency key (a second exec for
the same run id is refused). No on-disk state directory is used, so there is
no 0700 directory to manage; a durable nonce store can be added in A1.3
without changing the grant format, using the nonce as the idempotency key.

### Diagnostics

Grant errors and decision encodings contain fixed text plus labels, digests
and policy versions. They never echo argv values, env values, or the nonce.
Requests carry env *names* only, so secret values are structurally excluded
from the digest and from all diagnostics.

## Security notes / limits

* Path checks are lexical (no filesystem access). Symlink, hard-link and
  mount-escape checks belong to the exec boundary (A1.1/ADR-0012 §6).
* Argument scanning is conservative and does not parse shell grammar. It can
  over-classify (`echo reboot` is denied), which fails closed.
* An empty `allowed_operations`/`allowed_argv_prefixes` list grants nothing;
  there is no wildcard.
* `evaluate` is pure and deterministic; it makes no network or clock calls.
  The caller supplies `now_ms` and `primary_reachable`.

## Tests

`moon test --target native services/policy` covers SHA-256 known vectors,
digest stability and the pinned vector, snapshot round-trip/strict
decode/pinned hash/tamper rejection, every decision class, offline and
stale-policy semantics, grant binding/freshness/replay/TTL, bounded nonce
eviction, and secret-free diagnostics.
