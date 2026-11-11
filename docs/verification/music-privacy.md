# Mandatory Invidious playback verification

Checked on 10 November 2026 in the existing working tree based on `40826fd6`,
including the local fixes for issues 27, 28 and 29. The requested policy is that
direct Google playback must be unavailable in the app, rather than an opt-in.

## Implementation

- Production Music has a network-free catalog contract and an Invidious adapter.
  The old direct YouTube Music implementation and parser fixtures are retained
  only under `test/music/support/`; they are not part of the application.
- Every Invidious API request requests `local=true`. Video, audio and download
  candidates must resolve to their selected instance after supported media-proxy
  rewriting. Signed Googlevideo queries retain their original spelling and
  receive the original host parameter required by the Invidious proxy.
- The phone and TV direct-playback switches and their runtime preference API are
  removed. Legacy `use-proxy=false` values remain import-compatible but have no
  effect. Connection-help browser links also request `local=true`.
- Supported Google artwork uses Invidious image routes. Unsupported official
  paths are omitted before requesting an image; notification and download covers
  follow the same rule. Independent artwork services retain their own routes.
- Dart and Android transports reject known official YouTube catalog, media and
  artwork destinations. The checks cover initial requests, redirects, independent
  adaptive stream children and background API requests, including through SOCKS.
  An unavailable Invidious route never enables a direct YouTube fallback.

The host checks inspect the actual destination, not strings inside signed query
parameters. An Invidious URL containing `host=rr1.googlevideo.com` is therefore
allowed. Invidious itself still fetches content from YouTube upstream; the policy
keeps those official connections out of Videre's application transport.

## Automated checks

- Pinned `dart tools/validate.dart` passed formatting, configured analysis and
  2,266 offline tests, with four opt-in live skips. Existing nonfatal application
  diagnostics remain; strict regression analysis passed.
- The five validation-helper checks, 14 Windows release-helper safety checks,
  10 APK-signing helper tests and `git diff --check` passed.
- `:videre_proxy:testDebugUnitTest` passed all 82 native JVM transport tests.
  New privacy cases assert rejection before route lookup/DNS or a SOCKS
  connection, including an instance redirect to an official endpoint. These
  tests use controlled local fixtures and contact no official endpoint.
- Regression tests cover legacy false preferences, source selection, exact
  signed queries, request origin and credentials, unsupported artwork without a
  cache/download request, phone/TV setting removal, and missing Music adapter
  methods failing without a direct catalog fallback.

The tested debug APK is
`build/music-privacy-acceptance/app-debug-music-privacy.apk`, SHA-256
`f623a10ce66324bb37add9eb3e52c2aa6d2db27fd07213eef8a87f90e7904be5`.
Its packaged Dart kernel matches a fresh compile after the final source edit,
and its DEX files include both native request and redirect guards.

Profile APK builds also passed for `armeabi-v7a`, `arm64-v8a` and `x86_64`.
For each ABI, a forced compile was newer than the final application source;
compiled and merged AOT libraries matched, stripping preserved the ELF build ID,
and the packaged library matched the stripped output. Both native guards were
present in every APK. Hashes and build IDs are recorded in
`build/music-privacy-acceptance/profile-build-identity.json`.

## Android acceptance

The exact debug APK above was installed over the existing signed-in app on the
Android 16/API 36 x86_64 phone emulator without resetting account data.

- `https://invidious.nerdvpn.de`: Music home, search and artwork loaded. PSY audio
  advanced to 00:28, continued for nine seconds with Android Home in front, and
  returned paused at 00:37. The actual Video player settings had no direct-playback
  switch.
- `https://invidious.dvbeckwitt.duckdns.org`: Music search, artwork and PSY audio
  played. A regular video decoded and advanced from 17:36 to 17:41 before pausing.
- The limited app Service log recorded the two instance hosts, SponsorBlock and
  Return YouTube Dislike, with no official YouTube host. This is supporting
  application-log evidence, not exhaustive packet capture. Controlled transport
  tests separately establish rejection before connecting to official endpoints.
- The regular-video screenshot exposed an unrelated metadata-statistics row
  overflow on the emulator's narrow phone display. This check does not establish
  that all existing layouts are overflow-free.

Playback was paused and closed, the public NerdVPN instance was restored, and
the emulator was left on Music Home with the saved login retained. The runtime
receipt is `build/music-privacy-acceptance/native-acceptance.json`.

Logs are retained locally under `build/music-privacy-*.log` and
`build/youtube-transport-*.log`; build identity and runtime evidence are under
the ignored `build/music-privacy-acceptance/` directory.

The transport guarantee covers application requests and playback, not a user's
explicit navigation in an external browser or another application. Local
Windows/Android emulator checks do not establish physical-device, Linux CI or
full Nix live-service-suite coverage. No commit, push or release was made.
