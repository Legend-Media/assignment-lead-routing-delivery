# Mock Recipients Server

A single, **dependency-free** Ruby process (stdlib only — no gems, no bundler) that
simulates the three downstream recipients, a DNC scrub endpoint, and the
asynchronous postback callbacks. Use it to develop and test your integrations
without any real third-party credentials.

## Run it

```bash
# basic (postbacks are logged but not delivered):
ruby mock_recipients/server.rb

# with postbacks delivered to your running service:
CALLBACK_URL=http://localhost:3000/postbacks/recipients ruby mock_recipients/server.rb

# custom port:
PORT=4100 ruby mock_recipients/server.rb
```

Default port is `3100`. Health check:

```bash
curl http://localhost:3100/health
```

## What it does

- Serves `/scrub/dnc`, `/apex/v2/leads`, `/beacon/api/addLead`, `/citadel/intake`
  with the exact contracts in [`../docs/RECIPIENT_APIS.md`](../docs/RECIPIENT_APIS.md).
- Each recipient is intentionally different (JSON vs form-encoded, header vs body
  auth, success-in-status vs success-in-body, retryable 503 / 429, duplicate 409).
- A few seconds after accepting a lead it fires a **postback** to `CALLBACK_URL`.
  **~25% of postbacks are sent twice** so you can prove your handling is idempotent.

## Notes

- State (seen claim IDs, rate-limit windows) is **in-memory** and resets on restart.
- The shared secret used for the postback `signature` is `mock-shared-secret`.
- Test API keys/tokens are in `docs/RECIPIENT_APIS.md`. They are fake.
- Tested on Ruby 3.2+. It only uses `socket`, `net/http`, `json`, `uri`, `csv`,
  `securerandom`, and `digest`.
