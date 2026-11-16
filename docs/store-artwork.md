# Store artwork and screenshot provenance

## Videre artwork

The Videre mark is original vector artwork authored for this project with
Codex: a split-ribbon V in violet and lavender, an inset play accent, and a navy
background. Editable sources are `assets/icon.svg`, `icon-with-background.svg`,
`icon_monochrome.svg`, `icon-splash.svg`, `banner.svg`, `tv-banner.svg` and
`github-banner.svg`. Wordmark lettering is outlined Segoe UI Semibold, rendered
with Windows WPF; the font's glyph shapes are not claimed as original artwork.
The newly authored mark and compositions follow the repository's
[AGPL-3.0 license](../LICENSE).

The 512 × 512 store icon, 1024 × 500 feature graphic and 1280 × 720 TV banner
are PNG renders of those vectors, copied to
`fastlane/metadata/android/en-US/images/`. No generated raster illustration or
mock UI is used in these assets.

## README figures

The README gallery was refreshed on 16 November 2026 using installed
**Videre 1.22.46+60918** on Android 16 / API 36, in the persistent
`Videre_NerdVPN_Test` emulator. All three PNGs are unedited **540 × 1080** native
Android captures in the app's dark theme. The emulator's original light theme
was restored afterward.

| File under `screenshots/` | Displayed screen |
| --- | --- |
| `videre-video.png` | Video player showing a frame from *Spring* with playback controls visible |
| `videre-music.png` | Music Home, with an empty saved-song library and genre searches |
| `videre-podcasts.png` | Add podcast form, with the keyboard dismissed and its example feed placeholder |

The video screenshot shows playback through a saved Invidious instance.
The displayed film frame comes from [Spring](https://www.youtube.com/watch?v=WhWc3b3KhnY)
© Blender Foundation | cloud.blender.org/spring,
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
See the [Blender Studio license notice](https://studio.blender.org/projects/spring/pages/about/).

`assets/features.png` is a generated seven-feature illustration with a navy
background, violet and lavender icons, and two compact rows. It was updated with the
built-in image-generation tool using the earlier graphic as a reference.
The palette follows the existing brand assets, using navy #171D36, violet
#7C3AED, lavender #B69CFF, and soft white #F4F1FF. The exact prompt is
retained in `assets/features.prompt.txt`.
Its only labels are Sponsor Block, Local Library, Background Playback,
Offline Downloads, TV Remote, YouTube Music, and RSS Feeds.
The README explains that music uses the selected Invidious instance.

## Android screenshots

The store screenshots show the real Videre Android application in an Android
emulator, with phone, tablet and TV layouts. A separate **Open movies
demo** profile connects to a local, unauthenticated Invidious-shaped API. That
API supplies genuine Blender film titles, durations and thumbnails from the
official Blender Open Movies service. It contains no personal viewing history
or account data. The thumbnails are displayed by Videre's normal UI; they are
not composited into a mock application screen.

All six screenshots were captured and visually checked using Videre
**1.22.35+60897** (debug APK) on Android 16 / API 36, AVD
`videre_publication_12230`. The APK SHA-256 is
`72bb27233124a0455558021fdaf573149af285c8788c0311b8ed0b34bd8aca3b`.
The screenshot paths below are relative to
`fastlane/metadata/android/en-US/images/`.

| Files | Resolution and density | Screens |
| --- | --- | --- |
| `phoneScreenshots/1.png`, `2.png` | 1080 × 2220, 440 dpi | Onboarding; Home with open-movie demo content |
| `tenInchScreenshots/1.png`, `2.png` | 1920 × 1200, 240 dpi | Home grid; profile picker |
| `tvScreenshots/1.png`, `2.png` | 1920 × 1080, 240 dpi | TV Home; Trending grid |

The TV images use Videre's forced TV interface on the same emulator; they do
not establish physical TV or remote-control acceptance. No playback screen is
included. These captures demonstrate the displayed app layouts, not successful
playback or availability of an external Invidious service.

## Movie artwork credits

The following unchanged source thumbnails are included in the local demo
catalog. Videre may scale or crop them as part of its normal thumbnail layout.
The films and their artwork remain under their respective Creative Commons
licenses; these credits do not imply endorsement by Blender.

| Film and attribution | Official thumbnail source | License and primary notice |
| --- | --- | --- |
| **Big Buck Bunny** — © copyright 2008, Blender Foundation / www.bigbuckbunny.org | [Official thumbnail](https://video.blender.org/lazy-static/thumbnails/bf1f3fb5-b119-4f9f-9930-8e20e892b898.jpg) | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/); [project license notice](https://peach.blender.org/about/) |
| **Spring** — © Blender Foundation / cloud.blender.org/spring | [Official thumbnail](https://video.blender.org/lazy-static/thumbnails/3d95fb3d-c866-42c8-9db1-fe82f48ccb95.jpg) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); [project license notice](https://studio.blender.org/projects/spring/pages/about/) |
| **Sintel** — © copyright Blender Foundation / durian.blender.org | [Official thumbnail](https://video.blender.org/lazy-static/thumbnails/0eb052d0-fd51-43e6-aa33-ecdbf77a5d40.jpg) | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/); [project license notice](https://durian.blender.org/sharing/) |
| **Cosmos Laundromat: First Cycle** — © Blender Foundation / gooseberry.blender.org | [Official thumbnail](https://video.blender.org/lazy-static/thumbnails/f507dfdc-e73e-45a4-9778-d758cbe1ce96.jpg) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); [Blender Studio content license](https://studio.blender.org/terms-and-conditions/) and [project CC BY confirmation](https://gooseberry.blender.org/production-update-2020/) |

Film metadata comes from the corresponding official
[Blender Open Movies channel](https://video.blender.org/video-channels/blender_open_movies).
Dates supplied by that service are upload dates, which can differ from original
film release dates. No audience statistics are invented for the demo.
