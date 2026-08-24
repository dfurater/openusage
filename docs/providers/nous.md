# Nous

Tracks your [Nous Portal](https://portal.nousresearch.com) subscription usage — credits, balance, and
monthly cap — the account your [Hermes Agent](https://hermes-agent.nousresearch.com) bills against.

## What it tracks

| Metric | Meaning |
|---|---|
| Monthly Cap | Spend this month against your account's monthly dollar ceiling (a dollar meter) |
| Credits | Subscription credits used in the current cycle, resetting at `cycleEndsAt` |
| Balance | Prepaid credit balance remaining |
| Credits Left | Raw remaining subscription credits, even when the tier has no monthly allotment |

The provider shows your plan name (Free / Plus / Super / Ultra) beside its name in the dashboard.

## Where credentials come from

Nous has no companion menu-bar app, but if you run **Hermes Agent**, OpenUsage reuses the Portal
OAuth session Hermes already keeps on disk — no extra login. Otherwise you supply a Portal API key.

Credentials are checked in this order, first match wins:

1. **Saved key:** `~/.config/openusage/nous.json` — the file Settings ▸ API Key writes:

   ```json
   { "apiKey": "npk-..." }
   ```

2. **Environment variable:** `NOUS_PORTAL_API_KEY` in your shell profile.
3. **Hermes shared OAuth state:** `~/.hermes/shared/nous_auth.json`.
4. **Hermes active profile:** `~/.hermes/auth.json` (`providers.nous.access_token`).

### The token-expiry handshake

Hermes's Portal access tokens are short-lived. OpenUsage deliberately **never refreshes them**:
Nous refresh tokens are single-use with rotation, so a second process refreshing them without
persisting the rotated token back would revoke Hermes's whole session chain. When the stored token
has expired, the Nous provider shows

> *Nous access token expired. Start Hermes once to renew it, then refresh again.*

and recovers on the next refresh after Hermes has run. If you use Hermes daily, you will never see
this — Hermes renews the token whenever it runs.

## Troubleshooting

- **"No Nous Portal login found"** — no credential in any of the sources above. Run
  `hermes setup --portal`, or create an API key at portal.nousresearch.com and add it under
  Settings → API Keys.
- **"The Nous Portal rejected this credential"** — the key/token was rejected (401/403). Re-login
  with Hermes or replace the saved key.
- **"Token expired"** — see the handshake above; start Hermes once and refresh.

## Under the hood

Two GET requests with a `Bearer` token against `https://portal.nousresearch.com`:

- `GET /api/billing/state` — balance and the monthly cap (`limitUsd` / `spentThisMonthUsd`). Required
  for a usable snapshot.
- `GET /api/billing/subscription` — tier name, `creditsRemaining` against `monthlyCredits`, and the
  cycle reset time. Best-effort: one failing endpoint never blanks the other's rows.

Only a joint 401/403 from both endpoints is treated as a rejected credential. A balance of $0.00 or
0 credits left renders as a measured zero, not "No data".
