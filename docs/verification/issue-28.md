# Issue 28 verification

Checked on 10 November 2026 in the existing working tree based on `40826fd6`,
including the local fixes for issues 27 and 29. The report is
[player space](https://github.com/DVBeckwitt/Videre/issues/28).

## Reproduction and repair

On the Android 16 x86_64 emulator, playing `M7lc1UVf-VE` through the signed-in
NerdVPN instance left the black **Requested backend: Server default** badge over
the video after all playback controls disappeared. Two idle captures eight
seconds apart confirmed it stayed visible. The normal backend discovery action
was needed to populate this account's backend capability metadata. Server default
remained selected, and the account and proxy configuration were preserved.

Both phone and TV controls painted the badge independently of their visibility.
An existing widget test explicitly required that old behavior. The replacement
regression failed before the patch with painted opacity 1 when it expected 0.

The badge now follows phone control visibility and TV control opacity, respects
the motion preference, and leaves the accessibility tree when hidden. It is
absent from mini-player and picture-in-picture views, and hidden beneath TV
settings and queue panels. The shared metadata label below the player is unchanged.
Retry, recovery and error notices retain their independent lifetime.

## Verification

- All 27 focused backend-notice widget tests passed, including touch/remote
  reveal, automatic hiding, current backend after recovery, hidden semantics,
  all motion preferences, mini-player/PiP and independent recovery feedback.
- The canonical `dart tools/validate.dart` passed formatting, configured analysis
  and 2,245 offline tests, with four opt-in skips. Application analysis retains
  the existing nonfatal diagnostics; strict regression analysis passed.
- All 14 Windows release-helper safety checks and 10 APK-signing helper tests
  passed. `git diff --check` passed.
- The pinned Flutter SDK built the x86_64 debug APK and profile APKs for
  armeabi-v7a, arm64-v8a and x86_64. The native test APK's SHA-256 is
  `59274d0eded0ee16dc2485dd3c57625f6fa85b82dcc3640f07c4037f3f175cf6`.
  Fresh compilation and the packaged Dart kernel/AOT identity were verified.
- On that debug APK, real NerdVPN playback showed the badge with controls,
  hid it after inactivity, showed it on another tap, and hid it again. Fullscreen,
  the mini-player and Android's native picture-in-picture view passed too.
- In the emulator's forced TV layout, the same live video played. D-pad Up
  revealed the title, timeline and backend badge; seven seconds of inactivity
  hid all three while decoded video continued. A second reveal/hide cycle passed.

The emulator was restored to phone mode and its original screen configuration,
with Fit unchanged and playback paused/closed. The signed-in NerdVPN account and
proxy settings remain intact; the updated debug APK is installed.

Local evidence is under the ignored `build/issue28-acceptance/` directory. Useful
captures are `baseline-after-controls-fade.png`,
`patched-controls-revealed-again.png`, `patched-idle-second.png`,
`patched-fullscreen-idle.png`, `patched-native-pip.png`,
`patched-tv-playing-controls.png` and `patched-tv-playing-idle.png`. Earlier TV
captures without `playing` in the name show the details screen and are not player
acceptance evidence. Build identity receipts and the regression/validation logs
are under that directory and `build/`.

These are Windows build and Android emulator results. No physical Android TV,
Linux CI or full Nix live-service suite was run for this UI patch. No commit or
push was made.
