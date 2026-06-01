# Recipient API Contracts

These are the downstream systems your service integrates with. They are served by
the **mock recipients server** (`mock_recipients/server.rb`, see its README). The
whole point of having three of them is that they are **deliberately different** —
different transport, auth, field names, and success semantics. A good solution
hides those differences behind one clean abstraction.

Base URL (default): `http://localhost:3100`

Health check: `GET /health`

---

## DNC scrub (suppression)

Call before dispatching. Mirrors a third-party suppression provider.

```
POST /scrub/dnc
Content-Type: application/json

{ "phone": "5551234567" }

200 OK
{ "phone": "5551234567", "blocked": true|false }
```

A blocked phone means the lead is **suppressed** and must not be dispatched.
`data/dnc_blocklist.csv` lists the same numbers for offline reference.

---

## Recipient A — Apex Legal Intake (modern JSON)

```
POST /apex/v2/leads
Content-Type: application/json
X-Api-Key: apex-test-key-123

{
  "source_claim_id": "RAV-1001",
  "claim":    { "first_name": "...", "last_name": "...", "phone": "...", "email": "..." },
  "incident": { "state": "TX", "date": "2026-04-02", "injuries": "..." }
}
```

- **Required:** `claim.first_name`, `claim.last_name`, `claim.phone`, `claim.email`
- **Success:** `202 { "claim_id": "APX-xxxx", "status": "accepted" }`
- **Errors:**
  - `401 { "error": "invalid_api_key" }`
  - `422 { "error": "validation_failed", "missing": [...] }`
  - `503 { "error": "upstream_unavailable" }` with `Retry-After` — **transient**, fires
    on `?flaky=1` or randomly (~1 in 6). Your client should **retry** these.

## Recipient B — Beacon Lawsuit Network (legacy, form-encoded)

```
POST /beacon/api/addLead
Content-Type: application/x-www-form-urlencoded

key=beacon-test-key-456&source_claim_id=RAV-1001&first_name=...&last_name=...&phone10=5553142271&case_type=auto_accident
```

- **Auth** is a form field `key`, not a header.
- `phone10` must be exactly **10 digits** (strip country code / formatting yourself).
- **The catch:** Beacon returns **HTTP 200 even on failure**. Success is in the body:
  - Accepted: `200 { "success": 1, "lead_id": "BCN######" }`
  - Rejected: `200 { "success": 0, "error": "duplicate" | "phone_must_be_10_digits" | "missing_name" | "auth_failed" }`
- A repeated `source_claim_id` returns `success: 0, error: "duplicate"`.

## Recipient C — Citadel Claims (JSON, bearer token, strict)

```
POST /citadel/intake
Content-Type: application/json
Authorization: Bearer citadel-test-token-789

{ "source_claim_id": "...", "first_name": "...", "last_name": "...",
  "phone": "...", "email": "...", "accident_state": "TX", "injuries": "..." }
```

- **Required:** `first_name`, `last_name`, `phone`, `email`, `accident_state`
- **Success:** `200 { "accepted": true, "external_id": "CIT-xxxxx" }`
- **Errors:**
  - `401 { "error": "unauthorized" }`
  - `409 { "error": "duplicate", "source_claim_id": "..." }` — duplicate `source_claim_id` (idempotency)
  - `429 { "error": "rate_limited" }` with `Retry-After` — more than **5 requests / 10s**. Back off and retry.
  - `422 { "error": "validation_failed", "missing": [...] }`

---

## Postbacks (conversions coming back to you)

A few seconds after a recipient accepts a lead, the mock server POSTs a conversion
event to your service at `CALLBACK_URL` (you set this when launching the mock
server, e.g. `http://localhost:3000/postbacks/recipients`).

```
POST {CALLBACK_URL}
Content-Type: application/json

{
  "recipient": "apex",
  "source_claim_id": "RAV-1001",
  "external_id": "APX-1a2b",
  "disposition": "signed" | "rejected" | "not_qualified",
  "occurred_at": "2026-06-01T08:16:11Z",
  "signature": "<sha256 hex>"
}
```

- Match the postback to your lead via `source_claim_id`, update the lead stage and
  record/finalize a **conversion**.
- **~25% of postbacks are delivered twice.** Handling must be **idempotent** — a
  duplicate must not create a second conversion or double-count anything.
- `signature` is `SHA256("{source_claim_id}:{disposition}:mock-shared-secret")`.
  Verifying it is **optional but encouraged** (robustness signal).
- Respond `2xx` quickly; treat unknown `source_claim_id` gracefully.

---

## Extensibility checkpoint — "Delta Direct"

You do **not** need to implement this. Instead, design so that adding it later is a
small, isolated change, and note in `ARCHITECTURE.md` exactly where it would plug in
(which class/file you'd add, what you would *not* have to touch).

> **Delta Direct** — JSON over `POST /delta/v1/intake`, auth header
> `X-Delta-Token: <token>`, body `{ "lead": { ...flat fields... }, "campaign": "auto" }`,
> success `201 { "id": "...", "ok": true }`, duplicates `200 { "ok": false, "reason": "dup" }`.

If adding Delta would require editing your routing engine, dispatch loop, retry
logic, or lead model, the abstraction isn't done yet.
