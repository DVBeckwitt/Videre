# For You and Discover scroll performance

With animations off, scrolling rebuilt the card lists and repeatedly decoded
the profile's recommendation history on the UI thread. The feed now rebuilds
its card layout when the viewport size changes and checks the learning setting
outside the scroll callback. Visibility checks still run during scrolling so
a card must stay at least halfway on screen for a full second to count as seen.
The first card has its own repaint boundary so leaving and re-entering the
viewport restarts its timer. [Issue 42](https://github.com/DVBeckwitt/Videre/issues/42)

## Android comparison

On November 19, 2026, we compared release source `v1.22.48` (`ad8545e6`)
with the patched source using Flutter 3.35.3 Android x86_64 profile builds.
The same 60 Hz Android emulator used a 540 × 1080 viewport and SwiftShader
software rendering. Videre's motion preference was Off. Each build used
a temporary profile with 48 local videos, 32 discovery videos served by a
local Invidious fixture, and 1,200 prior event IDs. The original profile and
animation setting were restored after the runs.

After warming each tab, we measured three pairs of 1.35-second up and down
swipes. Card titles and screen positions confirmed that both tabs scrolled.
The table shows the median of the three runs. Timing columns give the
95th percentile within each run. Frame counts cover only the active swipes.

| Tab | UI time, before → after | Raster time, before → after | Frames per swipe pair, before → after |
| --- | --- | --- | --- |
| For You | 22.03 → 7.61 ms | 28.94 → 32.98 ms | 48 → 64 |
| Discover | 25.38 → 8.37 ms | 30.27 → 32.37 ms | 41 → 59 |

The patched UI p95 stayed below 11 ms in all six runs, inside the 16.67 ms
frame budget. The emulator still missed frames. A separate 34-frame trace
recorded 499 ms of raster work, including 321 ms in Android GL buffer swaps.
Buffer-swap p95 was 22.24 ms and layer-tree paint p95 was 7.48 ms.
Physical-device scrolling remains unverified.

## Regression coverage

The Home widget tests cover stable card delegates during scrolling on both
tabs, interrupted visibility, and returning to For You while a fresh ranking
is pending. A separate warmed widget measurement using a 212,992-character
recommendation history took 334–336 ms for 60 scroll updates before moving
the consent check, and 69–88 ms afterward. These are widget-test wall times.
Recommendation-service tests also cover reading the filter list once per
synchronous batch of 100 candidates and honoring a filter edit before the
next queued ranking.

The local `build/issue-acceptance/` directory contains `frame-benchmark.py`,
the original `*-frames.json` samples, `frame-comparison.json`, and
`engine-diagnostic.json`. The comparison records both measured APK hashes.
