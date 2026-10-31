# Feedback service deployment preparation

For hosting on your own Windows PC instead of Render, follow [LOCAL_HOSTING.md](LOCAL_HOSTING.md). Both options run the same service and use the same GitHub App integration.

For handing the service to a different Windows computer, use [WINDOWS_HOSTING.md](WINDOWS_HOSTING.md).

Recommended host: a paid Render Node web service with a 1 GB persistent disk. This matches the service's SQLite receipts and optional image storage. Render's default filesystem is ephemeral, so a free web service cannot safely preserve these records across redeploys. No service has been created and no hosting charge has been authorized by these files. Review the current compute and disk price in Render before activation. [Persistent disk documentation](https://render.com/docs/disks).

## Prepared configuration

[render.yaml](render.yaml) uses the `0.5c-512mb` compute plan, one instance, `services/feedback` as the root, a tested build, `/health`, and a disk mounted at `/var/data`. Automatic deployments are explicitly off. Creating a Blueprint can still trigger its initial deployment; do that only when activation is authorized. Select `services/feedback/render.yaml` as its custom Blueprint path. These fields were checked against Render's current reference; account/API Blueprint validation and an actual deployment have not run. [Blueprint reference](https://render.com/docs/blueprint-spec).

Node is pinned to 24.22.1 through `NODE_VERSION`; the package supports the 24.x line. [Node version configuration](https://render.com/docs/node-version).

## Inputs required from the owner

1. A Render account/workspace and approval for the paid service and disk.
2. An authorized remote commit containing these files. This task has not pushed them.
3. A GitHub App installed only on **DVBeckwitt/Videre**, with **Issues: Read and write** permission and no unrelated permissions. User authorization and webhooks are unnecessary for this relay. Record its app/client ID and installation ID. GitHub installation tokens are scoped to this repository by the service. [GitHub installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation), [issue API permissions](https://docs.github.com/en/rest/issues/issues#create-an-issue).
4. A GitHub App RSA private key uploaded directly to Render as the secret file **github-app.pem**. The service reads `/etc/secrets/github-app.pem`; keep its contents out of chat, Git, the APK and logs. Add this secret file in the dashboard, not in the Blueprint. [Render secret files](https://render.com/docs/configure-environment-variables#secret-files).
5. `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID` and `PUBLIC_BASE_URL` filled from the actual app/installation and assigned HTTPS service hostname. The hostname must be an origin with no path, query, credentials or fragment. Example hostnames in these deployment instructions are placeholders; standard Videre builds use the [configured public endpoint](README.md#app-endpoint).

## Activation and acceptance

Once deployment is authorized, create the service from the prepared configuration, add the secret file and required values, then manually deploy the chosen commit. Missing keys or malformed configuration fail readiness. Confirm `/health` is ready, then use an explicitly authorized benign report to verify issue creation, optional PNG access, duplicate replay and restart persistence. Health alone does not verify GitHub access. Check that failures retain the draft and never claim an issue was created.

Standard Videre builds include the public feedback origin. For a different deployment, override `VIDERE_FEEDBACK_URL` with its actual HTTPS service origin (no path), as described in [app endpoint configuration](README.md#app-endpoint); the client appends `/v1/reports`. Test direct and Orbot routing before distributing a connected APK. Test fixtures and simulated receipts do not establish production GitHub delivery.

`TRUSTED_PROXY_ADDRESSES` is intentionally unset. Do not trust user-supplied forwarding headers. Until Render's actual immediate proxy addresses and header behavior are verified, rate limits use the observed proxy address and can be shared by users. Verify this before public rollout; preserve the global limits when configuring trusted forwarding or host-level controls.

## Operation and rollback

Keep a single service instance attached to the same disk. Record the deployed commit and preserve the SQLite file plus its WAL/SHM state in a consistent backup. Use SQLite's online backup facility or stop writes before a file-level copy; test restoring a backup separately. Render also provides disk snapshots, but restores can roll receipt state back and therefore require reconciliation with GitHub before accepting old retries. [Disk snapshots and constraints](https://render.com/docs/disks).

To roll code back, select the prior validated commit while retaining the disk. Do not replace the database with an empty file: it contains duplicate-prevention receipts and pending outcomes. Suspended service or a revoked GitHub App installation safely stops new issue creation. Preserve existing image URLs when moving hosts, since public issue attachments reference them.

Watch the documented 100 MiB attachment and 10,000 receipt caps. At capacity, new reports receive 503; existing confirmed receipts remain replayable. Do not silently delete pending records or attachments to free space. Establish a retention/export policy and increase storage limits only after reviewing the effect on existing public issue links.
