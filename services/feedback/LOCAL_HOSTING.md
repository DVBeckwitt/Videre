# Host Videre feedback on your own computer

Setting this up on a different Windows computer for public users? Use [WINDOWS_HOSTING.md](WINDOWS_HOSTING.md), including the portable bundle layout, GitHub setup, Cloudflare mode, startup and backup instructions.

The existing service runs directly on Node 24.22.1. It needs no Docker, runtime npm dependencies or Render subscription. The computer supplies storage and must remain running, awake and connected whenever feedback and screenshot links need to be available. Your internet connection and electricity still have their normal costs.

This setup prepares local operation. It does not create a GitHub App, publish a tunnel, change DNS, install an automatic startup task, open firewall ports or rebuild/release Videre. A real feedback submission needs the GitHub App credentials; an APK for public users also needs a stable public HTTPS origin.

## Local configuration

Use the Node version in `.node-version`. An older system `node` cannot run this service's SQLite implementation. The commands below assume `node --version` reports `v24.22.1`; otherwise invoke the correct Node executable by its full path.

From this directory:

```powershell
node local.mjs init
```

On Windows, this creates `%LOCALAPPDATA%\VidereFeedback\feedback.env` without overwriting an existing configuration. The default SQLite file is `data\feedback.sqlite` beside that configuration. A different absolute configuration path may be supplied as the second argument. Keep this directory outside source checkouts, temporary build directories and Nextcloud/OneDrive synchronization. Store it on a local disk, not a network share. The same directory must survive code updates and rollback.

Fill in these values in that private configuration file:

- `PUBLIC_BASE_URL`: the actual HTTPS origin, such as `https://feedback.your-domain.example`, without a path. The example is not a provisioned address.
- `GITHUB_APP_ID` and `GITHUB_INSTALLATION_ID`: the repository-scoped GitHub App described in [DEPLOYMENT.md](DEPLOYMENT.md).
- `GITHUB_PRIVATE_KEY_FILE`: an absolute path to the App's RSA private key, outside the repository. The key is a file on the hosting computer; do not paste it into chat or put it in the APK.

The launcher binds only to `127.0.0.1` and ignores inherited service configuration. By default it does not trust forwarded client-IP headers. The explicit `PROXY_MODE=cloudflare` option enables the supported same-host tunnel arrangement described below. Keep the default repository `DVBeckwitt/Videre` unless deliberately operating a separate service with a separate database.

Windows access control is inherited from the containing directory: Node's Unix file modes do not establish Windows ACL protection. Ensure only the hosting user and required administrators/system accounts can read the configuration, database and private key. Do not place these files in a shared/public user directory.

Check configuration, then run in the foreground:

```powershell
node local.mjs check
node local.mjs start
```

The check makes no GitHub request. A successful check or `/health` response establishes structural configuration, not successful GitHub authorization or issue creation. Stop the foreground service with Ctrl+C. Use one process and one durable database; do not run multiple copies against different databases for the same endpoint.

## Public access from Videre

For users outside your network, a named Cloudflare Tunnel can forward a stable HTTPS hostname to `http://127.0.0.1:8787`. It establishes outbound connections, so the service does not need an exposed home IP or a router port-forward. Set up the actual domain and tunnel in your own Cloudflare account before activating it. [Tunnel setup](https://developers.cloudflare.com/tunnel/get-started/), [how connections work](https://developers.cloudflare.com/tunnel/concepts/).

The intended path is:

```text
Videre → https://feedback.your-domain → tunnel → 127.0.0.1:8787 → GitHub App
                                                   └→ local SQLite receipts/images
```

Set `PUBLIC_BASE_URL` and the APK's `VIDERE_FEEDBACK_URL` to that same stable origin. No GitHub key or tunnel token belongs in the app. Keep HTTPS verification and the phone's selected SOCKS routing enabled. Browser login challenges in front of this API are incompatible with the app's native feedback client.

A Quick Tunnel's address changes when restarted and it is intended for testing. It is unsuitable as the URL in a distributed APK or in permanent GitHub screenshot links. [Quick Tunnel limitations](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).

For a direct Cloudflare Tunnel on the same computer, set `PROXY_MODE=cloudflare` and route the tunnel to exactly `http://127.0.0.1:8787`. This trusts a single valid `CF-Connecting-IP` only from that loopback peer. Malformed/duplicate values fall back to the connection address; `X-Real-IP` cannot override the Cloudflare address. Keep generic proxy fields blank and do not put a Worker that rewrites client addresses in this route. Other modes leave proxy trust off, so all tunnel users would share the five-new-reports/hour observed-address quota. The global quotas remain enabled in either mode. Verify the actual tunnel and separate-client behavior before rollout. [Cloudflare header behavior](https://developers.cloudflare.com/fundamentals/reference/http-headers/).

## Testing on your own Android device

An existing APK without `VIDERE_FEEDBACK_URL` remains unconfigured. Changing this server's configuration cannot activate Send in that APK.

For a temporary USB-connected test, `adb reverse tcp:8787 tcp:8787` lets a development APK reach `http://127.0.0.1:8787` with `VIDERE_FEEDBACK_ALLOW_HTTP=true`. Use the existing build workflow to supply those definitions. Remove that reverse mapping when finished. The emulator also supports `10.0.2.2`, but that address is not exempt from Videre's SOCKS routing; a successful loopback test does not verify public Orbot access.

The production service still requires a public HTTPS origin for screenshot URLs. A private-only route does not make screenshots accessible to GitHub readers. Use the documented injected test harness for simulated delivery; the production launcher has no fake-success mode. Do not expose a credentialed local service for testing and then submit reports without intending to create real issues.

Before distributing a connected APK, verify public health, one explicitly authorized issue, optional image retrieval, replay of the same report after a service restart, and both direct and Orbot phone paths. An outage must leave the app's report available for retry rather than reporting success.

## Operation

Once public activation is accepted, configure service startup/restart using an appropriate Windows service manager and a stable code installation. Do not point an unattended service at a disposable development worktree. No unattended startup is installed by this preparation.

Keep the machine awake while serving. If it goes offline, users cannot submit and existing screenshot links may stop loading until it returns. The app retains a failed submission for an explicit retry; it does not silently upload in the background.

Back up the SQLite database consistently, including its WAL state: use SQLite's backup facility or stop writes before copying. Preserve receipts and pending outcomes across updates. Do not delete the database to fix a retry or free space. The current limits are 10,000 receipts and 100 MiB of image data. See [storage and retry behavior](README.md#storage-retries-and-privacy) and [operation/rollback](DEPLOYMENT.md#operation-and-rollback).

Local verification uses `node --test test/*.test.mjs`, including launcher checks and the existing service regressions. No test creates an external GitHub issue.
