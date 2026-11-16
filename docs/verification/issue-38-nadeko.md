# Nadeko playback verification — 15 November 2026

Nadeko's video metadata loaded in Videre, but its proxied media refused playback.
The app cannot restore a disabled server endpoint. It continues to keep playback
on the selected Invidious origin and respects access refusals.

## Environment and observations

- Android acceptance used the existing `Videre_NerdVPN_Test` emulator, API 36,
  with Videre `1.22.46-beta.1+60916`. A new Nadeko guest entry was selected through
  the public picker. SOCKS was disabled; existing saved accounts were preserved.
- Browsing and the metadata test succeeded. Starting a video produced the native
  Media3 source error `HttpDataSource$InvalidResponseCodeException`, status 403.
- Anonymous host probes used the pinned Dart 3.9.2 `HttpClient`, Videre's actual
  user agent, and no cookies or credentials. Signed media URLs remained only in
  process memory. Media probes read at most 4 KiB and followed no redirects.

| Request through Nadeko | Observed result |
|---|---|
| `/api/v1/stats` and `/api/v1/popular` | 200 JSON |
| `/api/v1/videos/dQw4w9WgXcQ?local=true` | 200 JSON; 26 adaptive tracks and one progressive stream |
| `/api/v1/videos/tV5UilNUYRY?local=true` | 200 JSON; 13 adaptive tracks and one progressive stream, all on Nadeko |
| Fresh progressive and adaptive `/videoplayback` URLs, `Range: bytes=0-1023` | 403, plain body `Endpoint disabled`, with both Videre and Dalvik user agents |
| `/api/manifest/dash/id/tV5UilNUYRY?local=true` | 500; no manifest |
| `/watch?v=tV5UilNUYRY&quality=dash&local=true` | 418 browser challenge; no advertised video sources |
| Video metadata without `local=true` | Media URLs on `googlevideo.com`; none fetched |

Python requests with the same Videre user agent returned 403 for the video API,
while Dart and the native app succeeded. The transport-dependent difference was
not resolved. It is not evidence that the app's metadata API is universally
disabled. The playback conclusion rests on the native error and Dart media
probes, which agree.

## Change and limits

Nadeko was removed only from Videre's curated picker suggestions. The official
directory is unchanged; users can still enter Nadeko manually, and existing
saved entries remain intact. README status now records this observed failure.
No source fallback, origin policy, retry rule, or credential behavior changed.

Connection help already explains that a successful video API check can coexist
with unavailable streams. That wording is retained. No extra media preflight or
browser challenge workaround was added.

The two focused suites (`add_server_test.dart` and `connection_help_test.dart`)
passed all 46 tests, covering the curated filter, continued acceptance of a
custom Nadeko address, and connection-help behavior. Formatting checks passed
for both touched Dart files, and `git diff --check` passed for this change.
These tests do not establish browser playback or future server availability.
Task-local diagnostic receipts
are under the ignored `build/issue38-nadeko/` and `build/issue-38/` directories;
they are not APK assets or committed signed-URL records.

## Follow-up — 16 November UTC

Retested with the pinned Dart client and the current Videre 1.22.46 user agent.
Fresh metadata for `dQw4w9WgXcQ?local=true` returned HTTP 200 with 26 adaptive
tracks and one progressive stream. Both advertised media URLs returned
`403 Endpoint disabled`; the advertised local DASH URL returned HTTP 500.
Only Nadeko's origin was contacted, no redirects were followed, and media reads
were capped at 4 KiB. The new receipt is retained separately under ignored
`build/issue38-nadeko/nov16-probe.json`.

The operator's [third-party client statement](https://nadeko.net/announcements/invidious-and-the-bot-problem/)
explicitly says API access is disabled and restoration is not planned. The
current browser challenge repeats that API restriction. JavaScript compatibility
alone therefore does not restore supported third-party playback.

The deployed build reports source commit
`23977bab422fb418bf2402c20cbc7693f5a73ebd`. Its
[API serializer](https://git.nadeko.net/Fijxu/invidious/src/commit/23977bab422fb418bf2402c20cbc7693f5a73ebd/src/invidious/jsonify/api_v1/video_json.cr)
advertises the frontend media routes tested above, without a companion address
or authorization value. The
[website player](https://git.nadeko.net/Fijxu/invidious/src/commit/23977bab422fb418bf2402c20cbc7693f5a73ebd/src/invidious/views/components/player.ecr)
uses companion URLs with a server-issued `check` value instead. No supported
replacement app API was found. The exact deployment component emitting the
plain-text refusal was not established. Nadeko playback remains externally
blocked; this release must not describe it as fixed.
