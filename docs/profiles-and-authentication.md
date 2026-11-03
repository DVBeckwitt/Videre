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

## Verification

The canonical offline helper includes profile migration/isolation, account
switch recovery, late callbacks, watched queue retries, download resume, worker
ownership, and phone/TV widget regressions. Native transport tests run with
`:videre_proxy:testDebugUnitTest`. The additional Android device test
`GatewaySessionDeviceTest` exercises the real WebView cookie store; run it with
`:videre_proxy:connectedDebugAndroidTest` on an emulator/device with a current
WebView. Neither widget nor native cookie tests replace end-to-end playback and
sign-in checks against a configured protected instance.
