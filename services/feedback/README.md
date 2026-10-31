# Videre feedback service

This small Node 24.22.1 service accepts explicitly submitted in-app bug reports and suggestions, then creates issues through a repository-scoped GitHub App. Users do not need GitHub accounts. It has no runtime npm dependencies. GitHub credentials stay on the server.

Run it on your own computer with the [local hosting setup](LOCAL_HOSTING.md), or use the paid persistent-disk option in [DEPLOYMENT.md](DEPLOYMENT.md) and the prepared [Render Blueprint](render.yaml). Nothing in this directory provisions hosting, purchases a plan, or deploys itself.

For a separate Windows computer serving public users, use the complete [Windows host handoff](WINDOWS_HOSTING.md).

## App endpoint

Starting with `1.22.31-beta.2`, standard Videre builds use `https://feedback.dvbeckwitt.duckdns.org`. The app contacts the service only when the user sends a report; diagnostics and screenshots remain optional. GitHub credentials stay on the host.

For another deployment, pass `--dart-define=VIDERE_FEEDBACK_URL=https://your-service.example` to the Flutter build. Pass `--dart-define=VIDERE_FEEDBACK_URL=` to explicitly disable submissions while retaining local drafts. The client appends `/v1/reports`. Changing server configuration cannot activate older APKs built without an endpoint; those need an app update. Development HTTP remains disabled unless explicitly enabled for a supported loopback test address.

## Run and test

Use Node 24.22.1 (also pinned in `.node-version`):

```sh
cd services/feedback
node --test test/*.test.mjs
node --env-file=.env server.mjs
```

Copy `.env.example` to an ignored `.env`, fill in the real values, and store the GitHub App private key outside the repository. `/health` returns 503 until credentials are structurally configured; a 200 health response does not prove GitHub has granted the required permissions. The actual issue-creation acceptance check requires an explicitly authorized live report.

Tests use an injected fake GitHub transport and temporary SQLite files. They make no public GitHub submissions. The production CLI has no fake-success mode. Native test harnesses may construct `createFeedbackServer` with a fake adapter and `allowInsecureLoopback: true`; this exception only permits an HTTP loopback origin and is unavailable through production environment variables.

## API contract

`POST /v1/reports`, `Content-Type: application/json`:

```json
{
  "schemaVersion": 1,
  "submissionId": "b4a62198-6092-4e19-a229-2eae3d3f5949",
  "kind": "bug",
  "title": "Playback does not resume",
  "description": "I selected another backend and pressed Play.",
  "diagnostics": {
    "appVersion": "1.22.30",
    "buildNumber": "60883",
    "playerType": "video",
    "proxyEnabled": true,
    "recoveryPhase": "failed",
    "alternativeCount": 2
  }
}
```

- `kind`: `bug` or `suggestion`; title 1–120 and description 1–8000 UTF-16 code units, with nonempty trimmed content.
- `submissionId`: UUID v4, reused unchanged for an explicit retry of the same payload. A changed payload with the same ID returns 409.
- Omit diagnostics entirely when not selected. Allowed keys: `appVersion`, `buildNumber` (strings up to 64); `androidVersion`, `deviceModel` (strings up to 120); `playerType` (`none/audio/video/tv`), `recoveryPhase` (`trying/ready/succeeded/failed`), `alternativeCount` (integer 0–2), `proxyEnabled` and `manualSelection` (booleans). Strings reject controls, URLs and `@`. Unknown keys and invalid types are rejected.
- Omit screenshot entirely when not selected. Its shape is `{"mimeType":"image/png","base64":"..."}`. PNG only, at most 2 MiB decoded, maximum 4096 in either dimension and 8,388,608 pixels. Metadata chunks are stripped. No remote URL or local filename is accepted.
- Request body limit 3 MiB. No client-selected repository, credentials, raw logs or authorization headers are part of this protocol.

Successful creation returns 201; a confirmed replay returns 200:

```json
{"status":"created","issueNumber":123,"issueUrl":"https://github.com/DVBeckwitt/Videre/issues/123"}
```

An uncertain create returns 202 `{"status":"pending"}` and `Retry-After: 30`. It is not a success. The client should retain the identical submitted snapshot and offer an explicit retry to check it. Errors are safe codes in `{"error":"code"}`: 400 validation, 403 browser-origin rejection, 409 submission conflict, 413 too large, 415 unsupported content type, 429 rate limit, 502 definite GitHub rejection, 503 unavailable/busy/capacity. Unexpected upstream text and secrets are never returned.

`GET /images/<random UUID>.png` serves only stored pending/confirmed report images with PNG and `nosniff` headers. These attachments become public through their issue links; do not promise deletion from GitHub's image caches. `GET /health` supplies only readiness and schema version.

## Storage, retries and privacy

SQLite holds report ID, payload digest, lifecycle/receipt metadata and optional sanitized PNG bytes. It does not retain the report's free-text title/description or diagnostics after the request. GitHub receives the user-approved text and optional data. Descriptions are rendered as literal text, so supplied mentions, HTML and remote-image Markdown do not trigger additional requests or notifications.

The service persists `pending` before calling GitHub. A crash, timeout, malformed success or ambiguous server error is never blindly re-posted. An explicit retry looks for the exact report marker in up to 500 directly listed issues. If a matching issue is found, the saved receipt is returned. If not found or GitHub is unreachable, the report remains pending; absence from this bounded lookup is not proof that no issue exists. An operator must investigate older unresolved reports before changing their state. Never delete a pending record just to make a retry work.

The database is bound to the configured repository. Preserve it across deployment and rollback. Atomic attempt ownership prevents duplicate creates even if two processes accidentally touch the same database, but the supported deployment is one service process and one persistent volume.

Default limits: 5 new reports per observed client address/hour, 100 new reports/day globally, 30 submission requests/address/minute, 300 requests/minute globally, 8 concurrent submissions, 16 active image responses and 64 connections. The daily address hash is keyed with a server-only random salt and no raw address is stored; rate buckets expire after two days. Proxy headers are ignored unless the immediate proxy address is explicitly trusted. Invalid requests consume the request quota.

The generic server uses `TRUSTED_PROXY_HEADER=x-real-ip` by default; `cf-connecting-ip` is the only alternative. Exactly one valid IP header from an exact trusted peer is required. The local launcher manages these fields through `PROXY_MODE=none|cloudflare`; use the Windows guide for its direct loopback Cloudflare Tunnel configuration.

Storage stops accepting new reports at 10,000 receipts or 100 MiB of attachments. It returns 503 instead of deleting evidence. Monitor capacity, back up the SQLite database, and choose a documented retention policy before changing these limits. Submitted screenshots are public data but backups and database files remain private operator assets.

These bounds do not replace hosting-level abuse controls. Operate the public endpoint behind HTTPS and a proxy with bounded request bodies/timeouts. Ordinary app feedback must follow the app's selected SOCKS routing; this service cannot establish or bypass the phone's network policy.
