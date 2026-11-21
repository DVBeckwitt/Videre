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
no signed media URLs. The build tested restricted media to the selected Invidious origin.
The EU instance delegates media to separate Companion origins, a documented
Invidious deployment option. Serving the media and manifest at the selected
frontend's origin is one way to support players with a same-origin policy.
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

## Issue 48 playback check

In a separate guest profile on the Android 16 x86_64 emulator, the issue 48
candidate loaded the metadata and comments for `tV5UilNUYRY`. With the default
empty companion list, the player showed the separate-host error at 00:00.
The manifest and sampled audio and video tracks all redirected to
`https://eu.yt-comp5.chocolatemoo53.com` during this check.

After that exact address was added in the account's **Media companion hosts**
settings, the same video played. The Android media session reported 2.527
seconds and then 6.476 seconds, and the visible player reached 00:08. The
operator can direct other videos to different hosts. The reporter’s instance
remains unknown. [Issue 48](https://github.com/DVBeckwitt/Videre/issues/48)

A controlled Android test also exercised an instance with a usable alternative
on its own server. Its DASH endpoint redirected to a second listening port,
but its audio and video tracks stayed on the original port. With no companion
approved, the player opened those tracks, reached 00:24 of the 30-second
video, and made zero requests to the second port.

The Android setup check also found different hosts for the same test video
(`dQw4w9WgXcQ`) on different runs. The prompt listed the exact addresses with
every box unchecked. Continuing without allowing any host saved an empty list.
In another run the prompt offered `eu.yt-comp4.chocolatemoo53.com` and
`eu.yt-comp5.chocolatemoo53.com`. After approval for only the first host,
the Android media session advanced from 4.463 to 16.120 seconds for that video.

On the final build, the first account in a fresh profile was offered
`eu.yt-comp1.chocolatemoo53.com` and `eu.yt-comp4.chocolatemoo53.com`.
Only the second host was approved. Adding another account for the same EU
instance completed without a second prompt. Both account settings showed
exactly the approved host.

A second profile received its own prompt for the same instance. This time
setup continued with no hosts approved. After restarting Videre, adding
another account in that profile completed without another prompt. Both
accounts in that profile showed an empty list.
