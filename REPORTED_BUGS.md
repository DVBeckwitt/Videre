# Reported bugs

Last reviewed: 2026-07-12

This document records the open reports labeled `bug` in the upstream
[Clipious issue tracker](https://github.com/lamarios/clipious/issues), together
with the security and splash defects found during the initial Videre audit.
Issue descriptions below summarize reporter-provided information; they are not
independent confirmation that every report still reproduces in Videre.

## Status definitions

- **Fixed in Videre 1.22.17**: covered by the shipped change and regression or
  build evidence.
- **Open upstream; Videre unverified**: the upstream issue remains open and was
  not reproduced against Videre during this work.
- **Client failure mode covered in Videre 1.22.18; reporter environment
  unverified**: deterministic offline tests cover the client behavior, but the
  reported device and instance path has not been reproduced.
- **Fixed in Videre 1.22.18**: source and regression evidence cover the shipped
  defect.
- **Partially mitigated in Videre 1.22.18**: the documented attack path is
  reduced in the release, but a stated residual risk remains open.
- **Audit finding fixed in Videre 1.22.17**: found during source review rather
  than filed as an upstream issue.

## Fixed or directly addressed in Videre

| Report | Details | Status and evidence |
| --- | --- | --- |
| [#708: Thumbnail 404 prevents playback](https://github.com/lamarios/clipious/issues/708) | A request for `maxresdefault.jpg` can return 404. The failed thumbnail then blocks the usable video-card interaction instead of falling back cleanly. | **Fixed in Videre 1.22.17.** Cards prefer an exact max-resolution candidate, continue through fallback candidates, and keep foreground controls usable during loading and failure. Covered by offline widget tests. |
| Instance credentials sent to unrelated thumbnail origins | Source review found that authentication headers intended for the selected Invidious instance could be reused for external, lookalike-host, scheme-mismatched, or port-mismatched thumbnail URLs. This was a privacy and credential-boundary defect without an upstream issue number. | **Audit finding fixed in Videre 1.22.17.** Headers are now limited to the selected instance's exact normalized HTTP(S) origin, including effective port. Covered by origin-matching and off-origin request tests. |
| Android 7–11 dark splash omitted its artwork | The night launch theme pointed directly to a solid launcher color, bypassing the generated splash drawable and logo. | **Audit finding fixed in Videre 1.22.17.** The night theme now resolves through `launch_background`; Android release resources compile successfully. |
| A stalled playback setup blocks the next video | Source review found that switching videos waited forever when the prior native data-source setup never completed. | **Fixed in Videre 1.22.18.** A switch now cancels the Dart-side wait, detaches and disposes the obsolete controller, and ignores late completion. A regression proves the replacement starts while the old future remains unresolved. |
| Media credentials and unbounded destinations reached the native player | Source review found custom instance headers could follow redirects or adaptive child requests, while untrusted metadata could supply unlimited arbitrary HTTP(S) candidates. | **Partially mitigated in Videre 1.22.18.** Credential propagation is fixed: native media sources receive no instance custom headers. Starting URLs are limited to the selected exact origin or default-port HTTPS YouTube media hosts, fragments deduplicate, and progressive candidates and their displayed quality choices are capped at ten. The pinned native player can still follow unchecked redirects and adaptive child URLs; per-request destination enforcement remains open. |

## Playback and video loading

Unless noted above, these reports are **open upstream; Videre unverified**.

| Issue | Reported behavior and context |
| --- | --- |
| [#705](https://github.com/lamarios/clipious/issues/705) | No videos play on a Pixel 9 running Android 16/GrapheneOS with Clipious 1.22.15 and a private Invidious instance. **Client failure mode covered in Videre 1.22.18; reporter environment unverified.** Videre now validates and orders media candidates, retries pre-initialization failures once per source, isolates stale loads, and emits one terminal error after exhaustion. Covered by the offline video regression suite; the reporter's Pixel, GrapheneOS, and private-instance path was not runtime-verified. |
| [#680](https://github.com/lamarios/clipious/issues/680) | Opening a video shows “Could not load the video”; changing the selected server and toggling DASH did not resolve it. **Client failure mode covered in Videre 1.22.18; reporter environment unverified.** Videre now falls back across valid HLS, DASH, and progressive candidates without carrying retries across video changes. Covered by the offline video regression suite; the reporter's server-switch path was not runtime-verified. |
| [#672](https://github.com/lamarios/clipious/issues/672) | Android TV audio plays over a black video surface; the reporter dates the regression to 1.22.7 while the same version works on a phone. **Build-verified candidate mitigation; runtime verification pending.** Videre sets `io.flutter.embedding.android.EnableImpeller=false` at application scope, and the merged APK manifest contains the opt-out. Playback still requires confirmation on an affected Nvidia Shield and the previously working phone before this can be marked fixed. |
| [#656](https://github.com/lamarios/clipious/issues/656) | The player opens but some homepage videos never load across the reporter's available servers. |
| [#649](https://github.com/lamarios/clipious/issues/649) | Subscription channel pages and videos remain loading instead of opening; the reporter noted the selected server might be involved. |
| [#646](https://github.com/lamarios/clipious/issues/646) | Shorts are listed but tapping them neither plays nor downloads them; already-published shorts also display nonsensical negative premiere times. |
| [#580](https://github.com/lamarios/clipious/issues/580) | With DASH enabled, selecting a resolution above 480p has no effect. Reported on Android 12 with Clipious 1.19.12. |
| [#555](https://github.com/lamarios/clipious/issues/555) | Some specific videos fail across multiple instances and phones while other videos play, with no clear content pattern identified. |
| [#515](https://github.com/lamarios/clipious/issues/515) | Enabling instance-proxied video produces a black screen; disabling proxying restores playback. The instance's web proxy reportedly works. |
| [#464](https://github.com/lamarios/clipious/issues/464) | Playback hangs after fewer than ten minutes and requires force-closing the app. |
| [#374](https://github.com/lamarios/clipious/issues/374) | Videos opened from search are inconsistent: some play and others do not. |

## Instance, network, and authentication handling

| Issue | Reported behavior and context |
| --- | --- |
| [#674](https://github.com/lamarios/clipious/issues/674) | Distinct backend subdomains such as `inv1` and `inv2` cannot be retained or switched independently; the app appears to collapse or ignore the subdomain difference. |
| [#599](https://github.com/lamarios/clipious/issues/599) | Channel pages stop loading when the Invidious server is protected by HTTP Basic Auth, although they work when Basic Auth is disabled. |
| [#598](https://github.com/lamarios/clipious/issues/598) | Token login is unavailable when HTTP Basic Auth credentials are configured; only cookie login is offered. |
| [#444](https://github.com/lamarios/clipious/issues/444) | A directly reachable local Invidious server loads thumbnails and videos in a browser but Clipious shows failed thumbnails and cannot play video. The report discusses non-TLS ports and external-domain configuration. |
| [#403](https://github.com/lamarios/clipious/issues/403) | A LAN-only Invidious instance behind an HTTPS reverse proxy is rejected as invalid in the app even though its web UI is reachable; direct IP/port access reportedly behaves differently. |

## Links, media controls, and app lifecycle

| Issue | Reported behavior and context |
| --- | --- |
| [#691](https://github.com/lamarios/clipious/issues/691) | Sending a YouTube media URL to Android TV opens Clipious but does not start playback. A cold start can produce a blank screen; an already-running app stays on its current screen. |
| [#558](https://github.com/lamarios/clipious/issues/558) | Shared YouTube links are not executed as videos after Clipious receives them. |
| [#661](https://github.com/lamarios/clipious/issues/661) | A Bluetooth headset's pause control does not pause playback on Nvidia Shield. |
| [#629](https://github.com/lamarios/clipious/issues/629) | Queue playback advances to the next video, but the displayed title remains from the previous item. Reported on Android TV and phones. |
| [#626](https://github.com/lamarios/clipious/issues/626) | The stop button does not stop playback unless pause/play is pressed first. |
| [#502](https://github.com/lamarios/clipious/issues/502) | The notification media stop action dismisses the widget but leaves background playback running unless playback was paused first or the app is foregrounded. |
| [#501](https://github.com/lamarios/clipious/issues/501) | On Nvidia Shield TV, pressing Home or switching apps produces a temporary black screen. Reinstalling and clearing data did not help. |
| [#488](https://github.com/lamarios/clipious/issues/488) | Minimizing the player sometimes causes an apparently random full UI refresh and blanking. |
| [#465](https://github.com/lamarios/clipious/issues/465) | The phone follows its normal sleep timeout while video is playing instead of keeping the display awake. Reported on OnePlus Open. |
| [#676](https://github.com/lamarios/clipious/issues/676) | The crop/stretch-to-fill fullscreen option does not remove black borders as expected. |

## Playlists, subscriptions, and history

| Issue | Reported behavior and context |
| --- | --- |
| [#621](https://github.com/lamarios/clipious/issues/621) | On-device subscriptions usually fail to populate even though newly published videos can be opened through individual channel pages. Retrying and switching instances did not reliably help. |
| [#552](https://github.com/lamarios/clipious/issues/552) | Under reproducible playlist conditions, only the first page of videos is shown. |
| [#548](https://github.com/lamarios/clipious/issues/548) | Playlists over 100 items remain loading or expose only the first 100 items when played. |
| [#376](https://github.com/lamarios/clipious/issues/376) | The subscription feed repeatedly pins an older video above newer entries even though the Invidious web feed is correctly ordered. |
| [#367](https://github.com/lamarios/clipious/issues/367) | Existing server-side Invidious subscriptions do not appear in Clipious, although subscriptions created in Clipious can synchronize between devices. |
| [#362](https://github.com/lamarios/clipious/issues/362) | Android TV search history remains empty despite search history being enabled and configured to retain entries. |

## UI, rendering, notification, and audio selection

| Issue | Reported behavior and context |
| --- | --- |
| [#709](https://github.com/lamarios/clipious/issues/709) | After rotating to landscape, the bottom-right add button is clipped and overlaps another control. |
| [#681](https://github.com/lamarios/clipious/issues/681) | Android TV shows graphical corruption in both browsing UI and video output on versions 1.22.7 and 1.22.8. |
| [#619](https://github.com/lamarios/clipious/issues/619) | Foreground-service and notification-category settings are described as confusing or contradictory for periodic new-video checks. |
| [#523](https://github.com/lamarios/clipious/issues/523) | The share action and neighboring icons are vertically misaligned and unevenly spaced in the video context menu. |
| [#456](https://github.com/lamarios/clipious/issues/456) | Audio-only playback can select a non-English audio track because multi-language audio selection is not handled consistently. |

## Interpretation and maintenance notes

- An open issue is a report, not proof of a current Videre defect. Server health,
  Invidious configuration, media availability, Android device behavior, and old
  app versions can produce overlapping symptoms.
- Several playback reports may share root causes, but they remain separate here
  because reporters supplied different environments and triggers.
- Before changing status, reproduce against the current Videre release and add
  the device, Android version, Videre version, instance version/configuration,
  exact media URL when safe, and relevant logs.
- When a report is fixed, retain the row and replace its status with the release,
  commit, and test or runtime evidence.
- The playback change is included in Videre 1.22.18 but still awaits
  reporter/device verification.
- Playback no longer supplies custom instance headers to native media requests.
  This is a security migration with no stored-data change. An authenticated
  reverse proxy that requires those headers for media must expose unauthenticated
  media URLs or playback will fail.
