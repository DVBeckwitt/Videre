# Set up Videre feedback on the hosting Windows computer

Use this guide **on the other Windows computer**, which will serve all Videre users. Nothing needs to run on the development PC. The transfer ZIP contains service code and tests, not credentials, an APK, Node, or an existing database.

The finished setup is:

```text
Videre → your permanent HTTPS address → Cloudflare Tunnel
                                         ↓
                         Node on 127.0.0.1:8787 → GitHub issues
                                         ↓
                              private local SQLite storage
```

You need a Windows account on that computer, a domain you control in Cloudflare, and permission to install a GitHub App on `DVBeckwitt/Videre`. The host must stay awake and online. Installing this service does not release Videre; a separate test APK must later be built with the chosen HTTPS address.

## 1. Install Node and unpack the transfer ZIP

Install the Windows Node **24.22.1** package for the host's architecture from the [official release page](https://nodejs.org/en/blog/release/v24.22.1). This is the tested version; the launcher permits compatible later 24.x versions, which should also pass the included tests before use. Do not substitute Node 16, 20, 22, 25 or 26. Restart PowerShell after installation and check:

```powershell
node --version
```

Extract the ZIP to `%USERPROFILE%\VidereFeedbackService`. Keep its directory layout: `services\feedback\local.mjs` must remain under the extracted root. Use an ordinary local folder, outside Git, Downloads cleanup, OneDrive and Nextcloud. Do not overwrite an existing live installation while it is running.

Open PowerShell as the Windows user who will run the service:

```powershell
$serviceRoot = Join-Path $env:USERPROFILE 'VidereFeedbackService'
Set-Location -LiteralPath $serviceRoot
node --test services/feedback/test/*.test.mjs
```

All tests must pass. They use generated keys and fake GitHub responses; they create no public issues. No `npm install`, Flutter SDK or Android SDK is needed.

## 2. Create private configuration and protect the folder

```powershell
node services/feedback/local.mjs init
$feedbackPrivate = Join-Path $env:LOCALAPPDATA 'VidereFeedback'
$feedbackConfig = Join-Path $feedbackPrivate 'feedback.env'
```

`init` never overwrites an existing file. If it reports `configuration_already_exists`, inspect and reuse the existing setup instead of deleting its database. The data directory must be separate from the extracted code directory.

Before adding a key, restrict the private folder to the hosting user, SYSTEM and administrators. This block changes only the named feedback folder; run it as the hosting user:

```powershell
$feedbackDirectory = Get-Item -LiteralPath $feedbackPrivate
if ($feedbackDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Use a normal local feedback directory, not a junction or link.'
}
$feedbackAcl = Get-Acl -LiteralPath $feedbackPrivate
$feedbackAcl.SetAccessRuleProtection($true, $false)
foreach ($feedbackOldRule in @($feedbackAcl.Access)) {
    $feedbackAcl.RemoveAccessRuleSpecific($feedbackOldRule)
}
foreach ($feedbackIdentity in @(
    [Security.Principal.WindowsIdentity]::GetCurrent().User,
    [Security.Principal.SecurityIdentifier]'S-1-5-18',
    [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
)) {
    $feedbackRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $feedbackIdentity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
    )
    $feedbackAcl.AddAccessRule($feedbackRule) | Out-Null
}
Set-Acl -LiteralPath $feedbackPrivate -AclObject $feedbackAcl
```

Node's Unix file-mode settings alone do not protect Windows files. On an existing setup, review any explicit file permissions as well. Store configuration, private keys and backups privately; do not send them with the ZIP or paste them into chat.

## 3. Register and install the GitHub App

On GitHub, open the repository owner's **Settings → Developer settings → GitHub Apps → New GitHub App**. Choose a unique name and use `https://github.com/DVBeckwitt/Videre` as the homepage. Disable the webhook's **Active** option. User authorization callbacks and a client secret are unnecessary for this service.

Grant **Repository permissions → Issues → Read and write**; leave unrelated permissions disabled. Register it for only the owner's account, then install it on **Only select repositories → Videre**. App visibility controls who can install the GitHub App, not who can submit through Videre. [GitHub registration](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app), [permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app).

Record the App ID from its settings and the installation ID from its installation configuration URL. Generate/download an RSA private key and place it in the protected folder as `github-app.pem`. Keep the downloaded key private; no key is provided in this bundle. [Installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).

Reset that file's permissions to inherit the protected folder, because a same-volume move can retain permissions from the download location:

```powershell
$feedbackKeyPath = Join-Path $feedbackPrivate 'github-app.pem'
$feedbackKeyItem = Get-Item -LiteralPath $feedbackKeyPath
if ($feedbackKeyItem.PSIsContainer -or
    ($feedbackKeyItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Use a regular private-key file, not a directory or link.'
}
icacls.exe $feedbackKeyPath /reset
if ($LASTEXITCODE -ne 0) { throw 'Could not secure the private-key file.' }
```

Review **Properties → Security** on the folder and key: only the hosting user, SYSTEM and administrators should have access. This changes only the named key, not other download files. [Windows copy/move permissions](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/permissions-on-copying-moving-files).

## 4. Choose the permanent address and configure the service

Choose a hostname on your domain, for example `feedback.your-domain.example`. This example is not a real endpoint. Keep the hostname stable: future APKs and GitHub screenshot links will use it.

Open the private configuration:

```powershell
notepad.exe $feedbackConfig
```

Fill it in using real values. Leave `FEEDBACK_DB` blank to keep the database at `%LOCALAPPDATA%\VidereFeedback\data\feedback.sqlite`:

```dotenv
PUBLIC_BASE_URL=https://feedback.your-domain.example
GITHUB_OWNER=DVBeckwitt
GITHUB_REPO=Videre
GITHUB_APP_ID=YOUR_APP_ID
GITHUB_INSTALLATION_ID=YOUR_INSTALLATION_ID
GITHUB_PRIVATE_KEY_FILE='C:\Users\YOUR_WINDOWS_USER\AppData\Local\VidereFeedback\github-app.pem'
FEEDBACK_DB=
HOST=127.0.0.1
PORT=8787
PROXY_MODE=cloudflare
TRUSTED_PROXY_ADDRESSES=
```

Replace the key path with its actual absolute path; `%LOCALAPPDATA%` variables are not expanded inside the `.env` file. Keep generic proxy addresses/header settings blank. `PROXY_MODE=cloudflare` selects the supported loopback Cloudflare arrangement, using `CF-Connecting-IP` only from `127.0.0.1`. Missing or malformed headers fall back to the connection address. Limits remain enabled: five new reports per observed client address per hour and 100 globally per day. Users sharing an address can still share a quota.

Run the check, then start the service:

```powershell
node services/feedback/local.mjs check
node services/feedback/local.mjs start
```

Leave that window open. In a second PowerShell window:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8787/health'
```

Expect `status: ready` and `schemaVersion: 1`. This proves the local listener and structurally valid configuration. It does **not** prove GitHub permissions or actual issue delivery.

## 5. Install the public HTTPS tunnel on this host

In the Cloudflare dashboard, create a named tunnel for this computer. Select Windows and its architecture; follow the dashboard's connector installation/service commands on **this hosting computer**. Enter tunnel credentials locally, never in chat, the repository or the APK. Add a published application route from the chosen hostname to **`http://127.0.0.1:8787`**. Use that exact IPv4 loopback address so it matches the trusted peer. [Official setup and prerequisites](https://developers.cloudflare.com/tunnel/get-started/).

The tunnel connects outward; do not open port 8787 on your router or bind Node to `0.0.0.0`. Confirm the Cloudflare connector is healthy. Do not use a Quick Tunnel: its hostname changes and it is intended for temporary testing. [Quick Tunnel limits](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).

Use a direct tunnel route, without a Worker that rewrites client addresses. Keep the visitor-IP header available. Cloudflare documents that Workers can affect `CF-Connecting-IP`; the service relies on the host and tunnel as the trusted boundary. Ordinary remote clients cannot choose the rate-limit address simply by supplying `X-Real-IP`. [Cloudflare header behavior](https://developers.cloudflare.com/fundamentals/reference/http-headers/).

The API must be reachable by native app clients. Do not require a Cloudflare Access browser login or interactive challenge on this API hostname. Retain applicable noninteractive protection and the service's own limits; do not disable protections for unrelated sites.

From a separate network, open `https://YOUR_ACTUAL_HOST/health`. It should return the same JSON through valid HTTPS. Then provide **only that public hostname** to the Videre maintainer so a connected test APK can be built. No server credentials go into an APK.

## 6. Verify real delivery before broad use

Coordinate one clearly labeled live test report with the repository owner; sending it creates a real GitHub issue. Verify the issue URL and optional screenshot, then restart the service and retry the same submission to ensure it returns the same issue. Keep the same submission ID and payload when checking retry behavior.

Use the connected test APK to test both direct access and Orbot/SOCKS routing. Confirm failed delivery preserves the draft. Check separate client-address quotas through the actual tunnel before public rollout. Local automated tests establish header handling, but do not verify your domain, Cloudflare policies, GitHub permissions or phone connectivity.

Older test APKs built without a feedback endpoint keep Send disabled. Standard builds starting with `1.22.31-beta.2` include Videre's public HTTPS endpoint; see [app endpoint configuration](README.md#app-endpoint) to use another host or disable submissions. Leave development HTTP disabled for public builds. Setting up this host does not update existing APKs.

## 7. Start after Windows reboots

After manual operation works, stop the foreground server with Ctrl+C. In Windows **Task Scheduler → Create Task**, configure:

- **General:** name `Videre Feedback`; use the same Windows account that owns the private folder; run whether that user is logged on or not. Supply that account's password through Windows when requested. The local-resources-only/no-password mode is unsuitable for GitHub network access.
- **Trigger:** at startup, optionally delayed 30 seconds.
- **Action:** start the full path to `node.exe`. Arguments are the full quoted launcher path, `start`, and the full quoted config path. Start in the extracted bundle root.
- **Settings:** restart on failure; do not start another instance if already running; disable the default multi-day execution time limit. Do not require the computer to be idle.

To display the correct action values, run this from the extracted bundle root:

```powershell
$nodePath = (Get-Command node.exe).Source
$launcherPath = Join-Path (Get-Location).Path 'services\feedback\local.mjs'
$configPath = Join-Path $env:LOCALAPPDATA 'VidereFeedback\feedback.env'
Write-Output ('Program: ' + $nodePath)
Write-Output ('Arguments: "' + $launcherPath + '" start "' + $configPath + '"')
Write-Output ('Start in: ' + (Get-Location).Path)
```

No password or key belongs in those arguments. Windows manages the task account credentials. Ensure the Cloudflare connector service also starts automatically. Reboot once and check public health without opening a foreground service. Configure the host's plugged-in power settings to stay awake; the screen can turn off. [Task security](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks), [task settings](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings).

These instructions do not register a task on the development computer. Startup and reboot behavior must be verified on the actual host.

## Backups, updates and troubleshooting

Back up the private data directory to a protected location. Use a SQLite-consistent backup, or stop the feedback task/process and confirm it has exited before copying the entire directory, including any database WAL/SHM files. Do not copy a live SQLite file through a cloud-sync folder. Retain pending receipts and attachments. A restored older backup can lose recent receipts, so reconcile it with GitHub before accepting retries.

For updates, stop the task, preserve the private directory, replace only the code with a tested bundle, rerun its tests/check, then restart and verify health. Keep one active process and the same database. Roll code back without resetting the database. Monitor the 10,000-receipt and 100 MiB image caps; capacity exhaustion rejects new reports instead of deleting evidence.

| Symptom | Check |
| --- | --- |
| `unsupported_node_version` or a missing SQLite module | The full Node executable path and installed version; use the tested 24.x runtime. |
| `https_origin_required` | A real HTTPS origin, with no path, credentials, query or fragment. |
| `github_*` configuration error | App/installation IDs, selected repository, RSA key path and hosting-user file permissions. Do not print the key. |
| Health ready but submission rejected/pending | GitHub installation permissions, upstream access and exact saved retry state. Health does not verify authorization. |
| Local health works, public health fails | Domain route, connector health, exact `127.0.0.1:8787` target and Cloudflare policy. |
| `429` responses | The request/report quotas, shared client addresses and configured proxy mode. Do not remove rate limits. |
| Port already in use | Another task or foreground instance; stop the duplicate, not an unrelated process. |
| Works until reboot | Task account/password, absolute paths, startup conditions, Cloudflare service and sleep settings. |
| Old screenshot links fail | Host uptime, original hostname and preserved database/image data. |

For support, share the public hostname and sanitized error code. Never share private keys, tunnel tokens, configuration contents or database files in public issues.
