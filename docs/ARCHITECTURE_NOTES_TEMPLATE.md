# Architecture Notes (fill this in)

Keep this short — a page or two. We care about your reasoning, not volume. Bullet
points are fine.

## 1. Overview
A few sentences on how the pieces fit together (ingest → validate → scrub → qualify
→ route → dispatch → postback) and the shape of your solution.

## 2. The lead lifecycle / state model
- How do you represent and persist lead stages? Why that approach?
- How do you make ingest and dispatch idempotent?

## 3. The integration layer (the heart of this assignment)
- What is the abstraction every recipient shares? Where do their differences live?
- How would you add **Delta Direct** (see RECIPIENT_APIS.md)? Name the file(s) you'd
  add and confirm what you would **not** need to change.

## 4. Routing
- How are routing rules expressed? How would a non-engineer change a recipient's
  accepted states or cap?

## 4b. CRM / operator interface
- Which UI approach did you choose (ActiveAdmin / Avo / Administrate / plain Rails / …) and why?
- How does an operator move through the flow: find leads by stage, inspect one lead's
  full history (transitions, dispatches, postbacks), and read the summary?

## 5. Robustness
- Timeouts, retries/backoff, and which errors you retry vs. surface.
- Duplicate postbacks, partial dispatch failures, malformed inbound records.

## 6. Trade-offs & what you'd do with more time
- What did you intentionally skip or simplify, and what would you do next?

## 7. AI tool usage (optional, no penalty)
If you used AI assistants, a sentence on how is fine. We're interested in your
judgment about what you accepted, changed, or rejected.
