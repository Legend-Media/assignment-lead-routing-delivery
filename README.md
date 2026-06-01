# Take-Home Assignment — Lead Routing & Delivery Service

Thanks for taking the time to do this. This is a **paid** take-home that mirrors the
kind of work you'd do on our CRM and lead-delivery systems. We've tried to make it
realistic and self-contained: everything you need to run and test it is in this repo,
with **no real third-party accounts or credentials required**.

We're far more interested in your **engineering judgment** than in how many features
you cram in. A smaller, clean, well-reasoned solution beats a large, sprawling one.

---

## What you're building

A service that takes in personal-injury / motor-vehicle-accident **leads** from
publishers, moves each lead through a clear set of **CRM stages**, and delivers
qualified leads to multiple downstream **recipients** — each of which has a
**different** API — then processes the **postbacks** those recipients send back.

```
Publishers ──▶ ingest → validate → DNC scrub → qualify → route → dispatch ──▶ Recipients
                                                                  ▲              │
                                                                  └─ postbacks ◀─┘
```

Read [`docs/DOMAIN.md`](docs/DOMAIN.md) first — it defines the domain, the lead
lifecycle/stages, the qualification rules, and the routing rules. Then read
[`docs/RECIPIENT_APIS.md`](docs/RECIPIENT_APIS.md) for the exact integration contracts.

## What we're assessing

This assignment is designed to exercise five areas. Keep them in mind as you build:

1. **Tracking leads through CRM stages** — an explicit, auditable lead lifecycle/state model.
2. **Third-party system integrations** — three recipients with different transports, auth, and success semantics.
3. **Cross-platform integration workflows** — ingest from publishers, deliver to recipients, and process asynchronous postbacks (a full bidirectional flow), all idempotently.
4. **Architectural decision-making** — how you structure the integration layer, the routing engine, and the state model; documented in `ARCHITECTURE.md`.
5. **Maintainability, extensibility, robustness, and DRY** — adding a new recipient should be a small, isolated change; the system should not fall over on bad data, transient errors, or duplicate events.

---

## Requirements

### Tech
- **Ruby on Rails (7+).** This matches the stack you'd be working in. Use PostgreSQL
  if convenient; **SQLite is fine** to keep setup light.
- **Background processing** is encouraged (ActiveJob with any adapter, including
  `:async`/inline) since dispatch and postbacks are naturally asynchronous.
- **Tests with RSpec** (or Minitest) covering the parts that matter most.
- The mock server is plain Ruby — you don't need to modify it, just integrate against it.

### Functional — must have
1. **Ingest** leads from `data/inbound_leads.json` (a rake task, seeder, or endpoint —
   your choice). Ingesting the same `source_claim_id` twice must **not** create a
   duplicate or re-dispatch.
2. **Validate & normalize** — required fields present; normalize phone (to 10 digits)
   and email. Invalid leads land in a terminal `invalid` stage with a reason.
3. **DNC scrub** via `POST /scrub/dnc` before any dispatch; suppressed leads never get
   dispatched.
4. **Qualify** against the intake rules in `docs/DOMAIN.md`, recording **why** a lead
   was disqualified. Rules should be easy to add/change in isolation.
5. **Route** qualified leads to all eligible recipients per the routing table
   (treat recipient config as **data**, not hard-coded branches). `test_lead`s and
   unroutable leads are never dispatched.
6. **Dispatch** to each recipient through a **single integration abstraction** that
   hides the per-recipient differences. Handle:
   - retryable failures (Apex `503`, Citadel `429` + `Retry-After`) with backoff,
   - Beacon's "success is in the body, not the status code" quirk,
   - duplicate rejections (`409` / `success:0 duplicate`) treated as already-delivered,
   - timeouts, and partial failure (delivered to one recipient, failed at another).
   Every dispatch attempt should be **auditable** (what was sent, what came back).
7. **Receive postbacks** at a `CALLBACK_URL` endpoint, match by `source_claim_id`,
   move the lead to its final stage, and record a **conversion**. Duplicate postbacks
   (~25% arrive twice) must be **idempotent**.
8. **Query the lifecycle** — be able to show, for any lead, its current stage and how
   it got there (and ideally a simple list/summary by stage).

### Nice to have (bonus, not required)
- A minimal UI (even ActiveAdmin or a couple of plain views) to browse leads by stage —
  a small full-stack signal.
- Verifying the postback `signature`.
- A summary/report (counts by stage, delivery success rate per recipient, conversion rate).
- CSV ingest (`data/inbound_leads.csv`) in addition to JSON.

> Don't sacrifice the must-haves or code quality to chase bonuses. We'd rather see
> the core done well.

---

## The environment

Start the mock recipients server (no gems needed):

```bash
# point postbacks at your running app:
CALLBACK_URL=http://localhost:3000/postbacks/recipients ruby mock_recipients/server.rb
curl http://localhost:3100/health
```

- Recipients, DNC, and postback contracts: [`docs/RECIPIENT_APIS.md`](docs/RECIPIENT_APIS.md)
- Mock server details: [`mock_recipients/README.md`](mock_recipients/README.md)
- Sample inbound data (with deliberate edge cases): `data/inbound_leads.json`,
  `data/inbound_leads.csv`, `data/dnc_blocklist.csv`

The sample data intentionally includes a DNC-listed number, missing/malformed
contact info, a duplicate `source_claim_id`, an out-of-coverage state, a stale
incident date, prequal failures, a `test_lead`, and one partially-broken record.
Your pipeline should handle all of them gracefully.

---

## Deliverables

1. Your Rails application, committed to a **Git repo** (a private GitHub repo you share
   with us, or a zipped repo with `.git` history — please keep meaningful commits).
2. A **`README.md`** for your app: how to set up, run, ingest, and test it, in order.
3. **`ARCHITECTURE.md`** — use [`docs/ARCHITECTURE_NOTES_TEMPLATE.md`](docs/ARCHITECTURE_NOTES_TEMPLATE.md)
   as a starting point. This is where you explain the integration abstraction, the
   state model, your routing approach, robustness decisions, and where "Delta Direct"
   (the extensibility checkpoint) would plug in.
4. **Tests** that run with a single documented command.

A reviewer should be able to clone your repo, follow your README, start the mock
server, ingest the sample data, and watch leads flow through to delivery and
conversion.

---

## Time, scope & logistics

- **Scope:** designed for roughly **4 days** of focused work. If you find yourself
  going well beyond that, stop and write down in `ARCHITECTURE.md` what you'd do next
  — knowing where to stop is part of the signal.
- This is a **paid** assignment; payment details are in your offer email.
- **Using AI assistants is allowed.** We use them too. We care that you understand,
  can defend, and would maintain every line you submit. A short note on how you used
  them (in `ARCHITECTURE.md`) is welcome but optional.
- **Questions are welcome.** If anything is ambiguous, make a reasonable assumption,
  write it down in `ARCHITECTURE.md`, and keep going — or reach out. Reasonable
  assumptions never count against you.

We're looking forward to seeing how you think. Good luck!
