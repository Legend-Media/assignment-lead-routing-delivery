# Domain Model & Lead Lifecycle

This document describes the business domain you are building for. Read it before
starting. It is intentionally close to a real lead-generation CRM but simplified
so the assignment fits in a few days.

## The business in one paragraph

We acquire **leads** — people who were in a motor-vehicle accident and may have a
personal-injury claim — from upstream **publishers**. Each lead must be validated,
suppression-checked (DNC), qualified against intake rules, then **routed** and
**dispatched** to one or more downstream **recipients** (legal intake partners),
each of which exposes a *different* API. Recipients later send back **postbacks**
telling us what happened to the lead (signed / rejected / not qualified). We track
every lead through its lifecycle and record the outcome as a **conversion**.

```
  Publishers ──▶  [ YOUR SERVICE ]  ──▶  Recipients (Apex / Beacon / Citadel)
   (inbound)        ingest → validate         (different APIs)
                    → scrub → qualify
                    → route → dispatch
                         ▲                          │
                         └──── postbacks ◀──────────┘
                              (conversions)
```

## Glossary

| Term | Meaning |
|---|---|
| **Lead** | A person + accident, with contact info and pre-qualification answers. |
| **Publisher** | Upstream source that sends us leads (`publisher_alpha`, etc.). |
| **Recipient** | Downstream legal-intake partner we deliver qualified leads to. |
| **Dispatch** | A single attempt to deliver one lead to one recipient (auditable). |
| **DNC scrub** | Suppression check against a Do-Not-Contact list before any dispatch. |
| **Qualification / intake** | Rule check (injuries, fault, recency, attorney, etc.). |
| **Routing** | Deciding which recipient(s) a qualified lead should go to. |
| **Postback / conversion** | Asynchronous callback from a recipient with the final disposition. |
| **`source_claim_id`** | Our stable identifier for a lead, echoed to recipients and back in postbacks. Use it for idempotency. |

## Canonical lead (inbound shape)

Inbound leads arrive as JSON (see `data/inbound_leads.json`). Treat this as the
*publisher* shape — your internal model is yours to design.

```json
{
  "source_claim_id": "RAV-1001",
  "publisher": "publisher_alpha",
  "received_at": "2026-05-31T09:00:00Z",
  "first_name": "Jordan",
  "last_name": "Carter",
  "phone": "+1 (555) 314-2271",
  "email": "user1001@example.com",
  "address_1": "123 Maple Ave",
  "city": "Springfield",
  "state": "TX",
  "postal_code": "73301",
  "accident_state": "TX",
  "incident_date": "2026-04-02",
  "role": "driver",
  "injuries": "neck and back pain",
  "lead_type": "accident_case",
  "test_lead": false,
  "trustedform_cert_url": "https://cert.trustedform.com/...",
  "prequal": {
    "has_injuries": true,
    "not_at_fault": true,
    "within_1_year": true,
    "has_no_attorney": true,
    "not_previously_dropped_or_settled": true,
    "has_received_medical_treatment": true
  }
}
```

The sample data deliberately includes messy records: missing email/phone,
malformed phone numbers, a duplicate `source_claim_id`, a DNC-listed number,
an out-of-coverage state, a stale incident date, prequal failures, a `test_lead`,
and one partially-broken record. Your pipeline must handle all of them without
crashing.

## Lead lifecycle (the CRM stages)

You must track each lead through explicit, queryable stages. The exact names and
storage are your decision, but the lifecycle must capture at least these
transitions and be auditable (you should be able to answer "why is this lead
here?"):

```
received
   │  validate (required fields, normalize phone/email)
   ├─▶ invalid ────────────────────────────────┐
   ▼                                            │
validated                                       │
   │  DNC scrub                                  │
   ├─▶ suppressed (on DNC) ─────────────────────┤
   ▼                                            │
scrubbed                                        │
   │  qualify (intake rules)                     │
   ├─▶ disqualified (failed rules) ─────────────┤
   ▼                                            │   (terminal, non-dispatched
qualified                                       │    states — never delivered)
   │  route (pick eligible recipients)          │
   ├─▶ unroutable (no eligible recipient) ──────┘
   ▼
routed
   │  dispatch to each recipient (with retries/idempotency)
   ▼
dispatched ──▶ delivered (≥1 recipient accepted)
   │           │
   │           ▼  postback arrives
   │       converted    (disposition: signed)
   │       rejected     (disposition: rejected / not_qualified)
   ▼
failed (all dispatch attempts failed)
```

Rules of note:

- A lead may be routed to **multiple** recipients. Track delivery per recipient.
- `test_lead: true` must **never** be dispatched to a real recipient.
- Re-ingesting the same `source_claim_id` must be **idempotent** (no duplicate lead, no double dispatch).
- A postback for a lead you already converted must be **idempotent** (no double-counting).
- Disposition vocabulary on postbacks: `signed`, `rejected`, `not_qualified`.

## Qualification (intake) rules

A lead is **qualified** only if all of the following hold. Missing data should be
treated as a failure (not an exception):

- `prequal.has_injuries == true`
- `prequal.not_at_fault == true`
- `prequal.within_1_year == true`
- `prequal.has_no_attorney == true`
- `prequal.not_previously_dropped_or_settled == true`
- `prequal.has_received_medical_treatment == true`

When a lead is disqualified, record **why** (which rule(s) failed). The intake rule
set should be expressed so that adding/removing/changing a rule is a small, isolated
change — not a rewrite of the qualification engine.

## Routing rules

Each recipient declares the states it accepts and a daily cap. Route a qualified
lead to every **eligible** recipient (accepts `accident_state`, under cap),
ordered by priority. The starting recipient config is below; treat it as data, not
hard-coded logic, so it can change without touching the engine.

| Recipient | `accepts_states`            | `daily_cap` | `priority` | Transport |
|-----------|-----------------------------|-------------|------------|-----------|
| apex      | TX, FL, GA, NC, OH          | 50          | 1          | JSON      |
| beacon    | TX, CA, NY, AZ, NV          | 30          | 2          | form-encoded |
| citadel   | FL, GA, CA, NY              | 20          | 3          | JSON+Bearer |

A lead whose `accident_state` matches no recipient is **unroutable**.

See `RECIPIENT_APIS.md` for the exact contract of each recipient.
