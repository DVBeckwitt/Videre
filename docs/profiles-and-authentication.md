# Profiles, watched history, and protected servers

Videre separates a person on the device from an account on an Invidious instance.
Changing accounts within a person keeps that person's local library. Changing
people changes the library, saved accounts, playback queue, and download list.

## Storage and migration

The existing library stays in its original stores and becomes the `default`
profile. Migration adds profile metadata without copying or deleting that data.
Other people use scoped stores in the same database. Legacy server records keep
their URL as their account ID; newly added accounts have independent IDs, so two
accounts may use the same URL. Credentials stay attached to their person and
account. Network proxy, certificate policy, download folder, and TV-mode settings
remain device settings.

Identity-sensitive operations require the original account ID. Deleting a legacy
account cannot redirect its downloads, pending authentication, or settings edits
to another account at the same server address.

Asynchronous writes and downloads capture their originating person and account.
A switch pauses playback, drains active download operations, refreshes the worker
snapshot, reloads the library, and resets navigation. If that fails, Videre restores
the previous selection. If restoration also fails, a blocking Retry screen keeps
the wrong library from becoming interactive. Downloads from other people remain
on disk; switching does not delete them. Worker notifications carry their owner,
and old notification actions cannot navigate into a different person's library.
Notifications are dismissed before switching and after the worker snapshot changes,
including notifications published by a worker during the transition.

Portable backup version 1 remains readable. Its optional `watchState` section
adds manual watched decisions. Restore affects the current person. Account
credentials, gateway cookies, remote history observations, and pending sync
operations are not portable library data.

## Saved playlists and resume

Playlist rows start playback at the selected occurrence, keeping the surrounding
playlist in the queue. Duplicate videos remain separate entries. Further pages
continue loading while either the detail screen or player owns the playlist;
partial failures keep loaded entries available and offer Retry.

Each person has a separate checkpoint for each playlist. **Resume playlist**
uses that occurrence and the video's saved timestamp. **Play from beginning**
starts the first available entry at zero. Music selections normally start at
zero; explicit Resume uses the saved timestamp. Resume also retains the
playlist's last audio/video playback mode. The existing watched badge at
90% does not discard the exact resume time or advance the playlist checkpoint.
Actual playback completion advances it. When the last entry is no longer
available, continuing with a known successor requires an explicit choice.

**Save playlist** keeps a reference and cached display metadata on this device.
It does not copy the videos or create an editable playlist. Public bookmarks
use the current backend and its network policy. Account-owned playlists retain
their original profile, account, and instance; they cannot silently open under
another account. The Invidious token API does not expose the website's external
playlist subscription action, so this save action does not promise account sync.

Portable version 1 backups include an optional `savedPlaylists` section for
public bookmarks and optional exact seconds in existing progress records.
Older backups still import. Credentials, private/account playlist references,
and playlist checkpoints are excluded; imported public bookmarks belong to the
receiving person. Deleting history clears the corresponding local checkpoint
and prevents a late playback callback from recreating it.

## Watched status and synchronization

Manual watched state is separate from playback position. Marking a video watched
does not replace its saved resume position; marking it unwatched resets resume
position and rejects late progress events from the old playback session. Starting
playback again can establish new progress.

The local change is immediate. When an account is signed in, its pending change
is persisted in an account-specific queue. Repeated toggles coalesce to the newest
choice, and an acknowledgement only removes the revision actually sent. Manual
changes, login, app resume, and explicit Retry can flush pending work.
Authentication failures pause automatic attempts until sign-in or explicit retry.
Account settings show pending or sign-in-required status.

Deleting or clearing server history is serialized with that account's pending
uploads. Successful deletion retires older queued changes while preserving newer
manual choices and local playback data. If an earlier upload remains unsettled,
deletion returns a retryable failure instead of reporting success while that upload
can still finish afterward.

Invidious history is membership, not a cross-device playback-position protocol.
Imported history can supply a watched badge when no local decision or playback
state is available; it does not invent a local seek position. A local manual
decision takes priority over imported history. Each sync pass is bounded: up to
50 pending mutations and 10 pages of 200 history entries. An incomplete pull does not treat
unseen entries as deleted. Exact cross-device last-writer ordering is unavailable
because the server API does not supply a comparable mutation timestamp.
See the [Invidious authenticated API contract](https://docs.invidious.io/api/authenticated-endpoints/).

## Authentik and other browser gateways

Protected sign-in uses an HTTPS browser flow and then Invidious token
authorization. Gateway cookies and the Invidious API token are separate. Cookies
remain in an account-specific native WebView profile, while transports resolve
them for each same-origin URL. They are not attached to external video, image, or
redirect origins. TLS certificate errors are not bypassed by the login browser.
An Android WebView without isolated-profile support reports that limitation.

API requests, images, captions, native video/audio streams, downloads, and worker
requests use the same account context. Session expiry requires sign-in; partial
downloads remain available for explicit retry afterward. Logout revokes the
account's session and late responses cannot restore its cookies. Internal context
headers are transport metadata and are removed before requests reach the server.
Gateway data is excluded from Android backup and device transfer.

Local fixtures cover protocol failures and session isolation, including Android
CookieManager behavior. They do not establish compatibility with every deployed
Authentik policy, MFA flow, or proxy configuration. A deployment must allow
Invidious token authorization and preserve its bearer authorization through the
gateway. Live deployment acceptance remains a separate check.
For Authentik, review [header authentication](https://docs.goauthentik.io/add-secure-apps/providers/proxy/header_authentication):
its optional interception of `Authorization` must not consume the Invidious token.

## NerdVPN API access

The canonical `https://invidious.nerdvpn.de` instance and its official onion
address support managed API keys. Clearnet browser sign-in uses PKCE and the
`:api_key` scope, and fetches the account's API key after the code exchange.
Existing clearnet accounts can sign in again to grant this scope, or enter a
manual key in account settings.

The supported onion host is
`nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion`,
on HTTP port 80 or HTTPS port 443. Enable Orbot or another Tor-capable SOCKS5
endpoint in **Network proxy** before using it. The onion setup hands off to the
separately installed Tor Browser. On versions that reject links from other apps,
choose **Copy address and open Tor Browser**, then paste the address into that
browser. Sign in there, wait for API eligibility if required, enable API access,
and enter the key in Videre.
Videre does not bundle Tor Browser. Its own proxy must be configured separately;
opening Tor Browser does not route Videre's requests. HTTP onion requests are
blocked before DNS or connection
when the app's SOCKS setting is off. HTTPS certificate checks remain mandatory.
Other HTTP hosts, ports, and onion aliases do not gain managed API-key access.

The onion preferences button explicitly targets the installed stable Tor Browser,
never an arbitrary default browser or a private browser component. Copying its
public preferences address requires a separate user action. If Tor Browser is
unavailable, including on a TV,
Videre shows installation guidance and the preferences address to open on
another device. API keys are obscured during entry. Adding an onion server
checks authenticated statistics and video metadata through Videre's configured
transport before saving it; a failed check clears the unsaved credential.
This grants API access for browsing and playback without importing browser
cookies or linking an Invidious account token for remote library synchronization.
The server must permit authenticated API and media requests from Videre;
the app cannot override eligibility restrictions or a gateway blocking the API.

A live check on November 9, 2026 reached the HTTP onion through Tor on Android
16 with the normal Android WebView, but Gandalf stopped before the login form
with "Web Crypto API is disabled". Chromium restricts Web Crypto to
[secure origins](https://chromium.googlesource.com/chromium/src/+/main/docs/security/faq.md).
This browser/gateway compatibility failure is separate from account eligibility.
The same test account subsequently signed in successfully through the separately
installed Tor Browser 16.0 on Android. Its onion preferences reported a six-hour
minimum account age.

A later check that day used a supplied, enabled API key on an isolated Android 16
emulator with Tor 0.4.9.15. Tor's check API confirmed the route. Authenticated HTTP
onion statistics, search, and video metadata returned HTTP 200. Videre added the
server, rendered video, and continued audio in the background with advancing
playback position and no media-session error. These playback checks used
**Proxy videos** off with **Network proxy** on. A transient connection close
during setup cleared after one explicit retry.

The HTTPS onion connection failed, and the HTTPS public instance timed out
through the same Tor setup. Later HTTP onion requests also timed out, including
an independent client; the attempt with **Proxy videos** on could not load fresh
metadata. These are bounded observations, not availability guarantees. Certificate
verification remained enabled. Public YouTube Music discovery uses a separate
endpoint and can be unavailable in the Tor exit's region even while onion
playback works.

A further bounded check late on November 9, 2026 (November 10 UTC) verified Tor
routing with separate US and DE exit constraints. On the US route, HTTP and
HTTPS onion probes failed to connect, while an independent authenticated HTTPS
public-instance statistics request returned HTTP 200 in 14.07 seconds. This
does not establish native account setup or playback. On the DE route,
independent public-instance statistics and video probes reached their 20-second
connection deadlines, and Videre's setup reached its 15-second request deadline.
No fresh playback was established. These results describe those routes and
attempts, not a universal onion-service outage; the earlier HTTP onion playback
success remains valid.

API keys and the native recovery credential are encrypted with Android Keystore
and scoped to the local profile, account, and exact origin (scheme, host, port).
Clearnet, HTTP onion, and HTTPS onion credentials are never shared automatically.
Transports resolve
the key for each API, image, media, download, and worker request. Legacy custom
header keys migrate into this store. The store is excluded from Android backup.

Settings retain the server's eligibility date and disabled-access state. The
account remains saved while its requests are paused. Users can check eligibility,
enable access in NerdVPN preferences, or choose another instance. Concurrent key
failures share one recovery attempt. Reads can retry once after recovery, while
writes require an explicit retry. Gateway rate limits and temporary outages keep
credentials and honor `Retry-After`. Ambiguous token errors prompt reauthorization
while preserving the saved login.

Android acceptance against an isolated SOCKS/onion fixture verified PKCE
sign-in, API-key retrieval, manual-key storage, restart persistence, one-request
key recovery, native video playback, and recovery after disabling/re-enabling
the proxy. This verifies client behavior, not live NerdVPN account eligibility
or compatibility with its currently deployed onion gateway.

## Verification

The canonical offline helper includes profile migration/isolation, account
switch recovery, late callbacks, watched queue retries, download resume, worker
ownership, and phone/TV widget regressions. Native transport tests run with
`:videre_proxy:testDebugUnitTest`. The additional Android device test
`GatewaySessionDeviceTest` exercises the real WebView cookie store; run it with
`:videre_proxy:connectedDebugAndroidTest` on an emulator/device with a current
WebView. Neither widget nor native cookie tests replace end-to-end playback and
sign-in checks against a configured protected instance.
