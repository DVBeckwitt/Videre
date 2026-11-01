# Image and download performance verification

Measured on 2026-11-01, comparing the local issue #9 image-proxy fix before and
after the performance changes. Both builds include the same proxy behavior.
The base Git revision was `a161cde49beaa56c9de8c4076a30a4d71bfa02b8`; the tested
changes were uncommitted. No push or hosted CI run was performed.

## Changes

- Choose the smallest supplied image that covers the rendered physical size,
  preserving the remaining fallbacks. Bound decoded dimensions while preserving
  aspect ratio, including the image provider painted by `DecorationImage`.
  DeArrow's explicit image choice remains unchanged.
- Reuse the app's reactive server selection. Read its current saved credentials
  synchronously instead of scanning server records asynchronously on every
  thumbnail rebuild. Standalone widgets resolve once per mount.
- Fetch download covers concurrently with media, with a five-second deadline.
  Covers are written to temporary files and promoted only when complete. Job
  completion, cancellation, deletion, and teardown join the artwork task.
- Keep TV channel/video content outside the per-frame blur animation builder.
  The blur and existing state-driven appearance/focus behavior remain intact.

## Method

Existing `videre_publication_12230` phone AVD, Android 16 / API 36, x86_64,
1080 x 2220 portrait viewport, density override 160, forced TV interface.
The AVD ran read-only without saving a snapshot. The attempted system rotation
setting did not persist; these measurements are not landscape-TV measurements.
Both builds used the repository-pinned Flutter SDK and JDK 21 in profile mode.

A temporary entrypoint wrapped production startup and recorded Flutter frame
timings, image-cache bytes, and selected-server reads. A deterministic local
Invidious-compatible fixture supplied 40 videos, 1280/640/320-wide JPEG variants,
800/176/88-pixel avatars, and a wide banner. Image responses were throttled to
512 KiB/s. Download artwork had an additional two-second response delay.
Procedural image content makes the byte savings specific to this workload.

Five trials per build: clear disk/decoded caches before opening the channel;
warm the TV video page, then perform 12 alternating transitions at 400 ms
intervals; download five separate audio items and delete each afterward.
The same harness and fixture were used for both builds. No builds or tests ran
concurrently with the measured trials. The measurements describe the combined
changes; they are not isolated attribution to each optimization.

## Results

Values are medians of five trials; ranges show the minimum and maximum trial.
MB denotes decimal megabytes. Frame figures are per-trial 95th percentiles.

| Metric | Before | After |
| --- | ---: | ---: |
| Channel decoded image cache | 18.0476 MB | 1.621856 MB |
| Channel image response bytes | 3.200862 MB | 0.078949 MB |
| Channel selected-server reads | 40 (30–40) | 8 (8–8) |
| Server reads during 12 TV transitions | 812 (792–817) | 0 (0–0) |
| TV UI build time, p95 | 3.35 ms (3.19–3.50) | 1.29 ms (1.24–1.39) |
| TV raster time, p95 | 47.87 ms (46.90–48.45) | 49.06 ms (48.62–49.35) |
| Metadata request to first media request | 3.858 s (3.849–3.864) | 0.539 s (0.525–0.543) |
| Download completion | 3.990 s (3.940–4.035) | 3.910 s (3.893–3.937) |

Decoded cache fell 91.0%, UI build p95 fell 61.4%, and media transfer began
86.0% sooner in this fixture. Total completion improvement is too small to
claim a meaningful gain. GPU raster time did not improve: blur remains the
dominant rendering cost on this emulator. Frames over the 16.67 ms stage budget
were 67 (62–73) before and 71 (68–76) after; the ranges overlap. This work does
not establish improved animation smoothness or performance on physical TVs.

## Correctness and artifacts

- Configured validation passed: formatting, source analysis with the existing
  292 tolerated diagnostics, clean strict test analysis, and 813 offline tests.
- Validation-helper self-tests, 10 Windows release checks, 10 signing tests,
  and 19 native proxy tests passed. All three production profile APKs built.
- Native cancellation during delayed artwork joined in 36 ms and left no
  download record, media, cover, or partial file. D-pad navigation and rendered
  images were checked. The normal APK was installed and smoke-tested without
  benchmark instrumentation; no matching runtime/image exceptions appeared.
- Live public-instance integration and hosted Linux CI were not run.

Run-specific sources, raw samples, logs, screenshots, and APKs are retained
locally under the ignored `build/perf/` directory. `summary.json` contains every
trial value; `before-*.json` and `after-*.json` contain the original samples.
`benchmark_main.dart`, `fixture.py`, and `run_benchmark.py` define the workload;
the fixture also uses the earlier `build/issue-9-*` acceptance media. These local
artifacts are not a committed benchmark suite and will be removed by cleaning
the build directory.

SHA-256 identifiers:

- Before instrumented APK: `8BF0C0DC750477C1D11C2F66BE8CC28652856FB9ED4793471BDB579DAA2A58A2`
- After instrumented APK: `8E99D475B3BEB2B8B7D515F1C409195672E225E8868C43D3525614139B595AEB`
- Production x86_64 APK at benchmark time: `A5C11AB1D809B0605CEC5C305173FE1DD5758E422B49FE855D0E6BDC07A494EC`
- Instrumentation source: `DFCDE65CBF9F0ED5A50B61E6D310064C808B6E13A58D65FE39635E75BA93FEFD`

## Follow-up regression review

The subsequent review reproduced and fixed two error-path defects:

- Two mounted thumbnails sharing a cached image stream could leave one stuck
  after that image failed. Fallback now advances from each widget's error view,
  after the frame, with guards against stale callbacks and disposed state.
- A cover endpoint returning HTTP 502 with a malformed JSON body could fail an
  otherwise valid media download. Artwork requests now skip error-body decoding;
  the existing optional-artwork error handling and cleanup remain in control.

Both retained regression tests failed before the repairs and passed afterward.
The complete configured checks passed again with 815 offline tests, the same
292 tolerated source-analysis diagnostics, clean strict analysis, and formatting.
All three production profile APKs rebuilt successfully. The earlier performance
samples remain unchanged; they predate these error-path repairs.

Both cases also passed in a profile build on the read-only Android 16 x86_64
AVD, using its native 1080 x 2220 viewport and density 440. Two mounted thumbnails
shared one failed 176-pixel request and both rendered the successful 88-pixel
fallback. A real audio/video download completed and muxed to a 266,393-byte WebM
after the cover returned malformed JSON with HTTP 502; no cover or partial files
remained. No matching unhandled, fatal, or image-codec exceptions appeared.
The controlled local fixture and acceptance wrapper use actual production
components and the download manager; they are not part of the normal entrypoint.
The final production APK was also installed and smoke-tested, with images
rendering, D-pad input exercised, and no matching runtime exceptions.
Evidence and scripts are retained in ignored `build/review/`, including
`acceptance.json`, `shared-fallback.png`, `production-smoke.json`, and
`validation.log`.

Final production x86_64 APK SHA-256:
`166846857959A110D27DEC70FEE5484205DF57E25297662FC83100F20528B0E2`.

## Repository audit and 1.22.32 verification

The later repository audit preserved the earlier image and download changes and
tested their integration with the new fixes on the same read-only Android 16
x86_64 AVD. Phone tests used 1080 x 2220 at density 440; tablet and TV layouts
used a 1920 x 1080 override at density 160. This does not replace physical TV
testing or cover every supported Android version.

Fresh profile builds exercised the production application with an ignored
instrumentation entrypoint and deterministic local fixtures. Checks covered:

- Real video/audio playback, media-session queue selection, shuffle, automatic
  next-video playback, speed/pitch/seek, Home-key background audio, and PiP.
- Shared image fallback, correctly routed artwork, and successful native
  audio/video muxing after a malformed HTTP 502 cover response.
- Download cancellation, HTTP Range resume, optional-cover timeout, stale
  retries, native WebM/legacy MP4 playback, and proxy-change cancellation.
- Real Android HTTP redirects, request coalescing, browse caching, Retry-After,
  and query encoding; FileDB/SQLite persistence, backup, and log retention.
- First-use Workmanager registration/cancellation and native notification
  creation/display with correct counts and payloads. This exposed an upstream
  callback-initialization defect, fixed by pinning `workmanager_android 0.9.0+2`.
- Rendered phone/TV selectors, subscription error/retry views, pagination, and
  TV search races. Deterministic delayed responses also exercised channel,
  playlist, and app/controller disposal paths on Android.

The final native download run resumed at byte 16,384, canceled pending metadata
in 23 ms and artwork in 35 ms, and canceled for a proxy change in 22 ms. The
optional artwork deadline completed at 5,082 ms. These are correctness checks
from one controlled run, not general performance estimates. Both warmed TV
channel and video animations performed zero selected-server reads during eight
transitions. No new animation-smoothness claim is made.

The configured offline suite passed 940 tests. The validation-helper self-tests,
Windows release safety tests, Python tools, and feedback relay tests also passed.
Native acceptance sources, structured results, logs, and screenshots are kept
locally in ignored `build/audit_native/`. Some race checks invoke production
controller/widget callbacks with controlled service responses; they do not
claim live public-instance integration. The normal entrypoint is built and
smoke-tested separately before release.

All three normal-entrypoint profile APKs built for version `1.22.32+60888`.
The x86_64 build was installed on the same emulator; touch navigation, rendered
images, and native video playback passed, with no matching runtime exceptions.
The Android proxy's 19 JVM tests passed as well. The final production x86_64
profile APK SHA-256 is
`2F50DA612EC2B625B4E1596EED52636F79022B5543A48FD0FE3B7C5FAA5B1D36`.
