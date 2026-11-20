# ChocolateMoo53 EU compatibility

Checked November 20, 2026 against the Videre profile build installed on the
existing Android 16 NerdVPN test emulator. The test used a disposable profile
and the exact operator-listed French endpoint, `https://eu.yt.chocolatemoo53.com`.
Videre's advanced setup test accepted the instance. [Operator announcement](https://www.chocolatemoo53.com/eu-server/)

| Check | Result |
| --- | --- |
| Public stats, search, and three sampled metadata requests | HTTP 200 with valid JSON. Stats identified the software as Invidious. |
| Setup test video `dQw4w9WgXcQ` | Metadata returned nine thumbnail variants on the selected host and 27 adaptive formats. |
| Local DASH requests for `tV5UilNUYRY` and `jNQXAC9IVRw` | HTTP 302 to separate `eu.yt-comp*` subdomains on the operator's domain. |
| Audio samples | One proxied audio request redirected to a Companion host with HTTP 307. Another returned HTML. |
| Native Watch for `tV5UilNUYRY` | Title, artwork, recommendations and comments loaded. By 14.58 seconds after Play, Videre showed “Could not load the video” and Retry with the playhead at 00:00. |
| Native Music | Search returned a PSY result. The bounded test did not confirm advancing audio after selection. |

The public probes stopped before following cross-origin redirects and retained
no signed media URLs. Videre restricts media to the selected Invidious origin.
The EU instance delegates media to separate Companion origins, a documented
Invidious deployment option. Serving the media and manifest at the selected
frontend's origin would make this deployment eligible for a new Videre test.
The EU instance remains outside the built-in picker. [Invidious Companion deployment](https://docs.invidious.io/installation/#advanced-improve-performance)

The emulator returned to the original Default profile with NerdVPN selected
and the saved playback record byte-for-byte intact. The temporary custom
entry exists only in the disposable acceptance profile.

Materialious 1.18.35 uses the selected instance's advertised DASH URL with
Invidious selected and YouTube fallback off. In its Android proxy path,
Materialious fetches the manifest with `local=true`, then supplies it to
Shaka and preserves absolute media addresses. This lets the player use the
operator's Companion route. Serving media nearby and the different startup
path can affect startup time. No matched Materialious timing comparison ran.
[Materialious player](https://github.com/Materialious/Materialious/blob/1.18.35/materialious/src/lib/components/player/Player.svelte#L689-L759) · [Manifest handling](https://github.com/Materialious/Materialious/blob/1.18.35/materialious/src/lib/player/manifest.ts#L4-L32)
