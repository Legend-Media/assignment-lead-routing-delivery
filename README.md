# Take-Home Assignment — Lead Routing & Delivery Service

Thanks for taking the time to do this. This is a **paid** take-home that mirrors the
kind of work you'd do on our CRM and lead-delivery systems. We've tried to make it
realistic and self-contained: everything you need to run and test it is in this repo,
with **no real third-party accounts or credentials required**.

We're far more interested in your **engineering judgment** than in how many features
you cram in. A smaller, clean, well-reasoned solution beats a large, sprawling one.

> **Start here:** **Fork this repository**, build your Rails app inside your fork,
> and submit a link to it (or a zip with git history). This repo is a **self-contained
> sandbox** — you can have the full environment running locally in under a minute with
> the commands in [Quick start](#quick-start-instant-sandbox) below. No external
> services, API keys, or accounts are needed.

---

## Quick start (instant sandbox)

The whole downstream environment is a single dependency-free Ruby process. From your
fork:

```bash
# 1. Start the mock recipients + DNC + postback server (stdlib only, no gems).
#    Point its postbacks at the endpoint your Rails app will expose.
CALLBACK_URL=http://localhost:3000/postbacks/recipients ruby mock_recipients/server.rb

# 2. In another terminal, confirm it's live:
curl http://localhost:3100/health
# => {"status":"ok","recipients":["apex","beacon","citadel"], ...}

# 3. Build your Rails app in this fork, then (your command) ingest the sample leads:
#    e.g.  bin/rails leads:ingest FILE=data/inbound_leads.json
#    and watch them flow: validate → scrub → qualify → route → dispatch → postback.
```

That's the entire sandbox — three differently-shaped recipient APIs, a DNC suppression
endpoint, and asynchronous conversion postbacks, all served locally. See
[`mock_recipients/README.md`](mock_recipients/README.md) and
[`docs/RECIPIENT_APIS.md`](docs/RECIPIENT_APIS.md) for the contracts.

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

1. **Tracking leads through CRM stages** — an explicit, auditable lead lifecycle/state
   model, **surfaced in an operator-facing CRM interface** (see requirement 8). We want
   to see how you model *and present* the flow.
2. **Third-party system integrations** — three recipients with different transports, auth, and success semantics.
3. **Cross-platform integration workflows** — ingest from publishers, deliver to recipients, and process asynchronous postbacks (a full bidirectional flow), all idempotently.
4. **Architectural decision-making** — how you structure the integration layer, the routing engine, and the state model; documented in `ARCHITECTURE.md`.
5. **Maintainability, extensibility, robustness, and DRY** — adding a new recipient should be a small, isolated change; the system should not fall over on bad data, transient errors, or duplicate events.

Because this is a **full-stack CRM** role, how cleanly an operator can *see and act on*
the lead flow matters as much as the backend that drives it.

---

## Requirements

### Tech
- **Ruby on Rails (7+).** This matches the stack you'd be working in. Use PostgreSQL
  if convenient; **SQLite is fine** to keep setup light.
- **Background processing** is encouraged (ActiveJob with any adapter, including
  `:async`/inline) since dispatch and postbacks are naturally asynchronous.
- **Tests with RSpec** (or Minitest) covering the parts that matter most.
- **CRM/admin UI:** ActiveAdmin recommended (our stack), but any Rails-ecosystem option
  is acceptable (Avo, Administrate, Trestle, Madmin, or plain Rails + Hotwire). See
  requirement 8.
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
8. **CRM / operator interface** — a working UI an operator could actually use to run
   the desk, not just a database dump. At minimum it should let someone:
   - browse and filter leads **by stage** (and by recipient / publisher / state),
   - open a single lead and see its **full lifecycle** — every stage transition with
     reasons, each dispatch attempt (recipient, what was sent, what came back), and any
     conversion/postback,
   - get an at-a-glance **summary** (counts by stage, delivery outcome per recipient).

   How you design this flow is part of what we're assessing. **We use and recommend
   [ActiveAdmin](https://activeadmin.info/)** (it's our stack), so it's the path of least
   resistance — but you're free to use **anything the Rails ecosystem supports**: Avo,
   Administrate, Trestle, Madmin, or hand-rolled Rails views with Hotwire/Turbo. Pick what
   lets you present the CRM flow most clearly and justify the choice in `ARCHITECTURE.md`.

### Nice to have (bonus, not required)
- Operator **actions** from the UI (e.g. re-dispatch a failed lead, requeue, mark reviewed).
- Verifying the postback `signature`.
- CSV ingest (`data/inbound_leads.csv`) in addition to JSON.
- Delivery/conversion **rates** over time, not just counts.

> Don't sacrifice the must-haves or code quality to chase bonuses. We'd rather see
> the core done well.

---

## The environment

The sandbox is the mock server from [Quick start](#quick-start-instant-sandbox) above.
Reference material:

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

1. Your Rails application, built **inside your fork of this repo** and shared as a link
   (or a zip with `.git` history). Please keep meaningful, incremental commits.
2. A **`README.md`** for your app: how to set up, run, ingest, open the CRM UI, and test
   it, in order.
3. **`ARCHITECTURE.md`** — use [`docs/ARCHITECTURE_NOTES_TEMPLATE.md`](docs/ARCHITECTURE_NOTES_TEMPLATE.md)
   as a starting point. This is where you explain the integration abstraction, the
   state model, your CRM/UI choice, your routing approach, robustness decisions, and
   where "Delta Direct" (the extensibility checkpoint) would plug in.
4. **Tests** that run with a single documented command.

A reviewer should be able to clone your fork, follow your README, start the mock
server, ingest the sample data, browse the leads through your CRM interface, and watch
them flow through to delivery and conversion.

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
