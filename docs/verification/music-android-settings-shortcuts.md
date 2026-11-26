# Android settings shortcuts in Music

## Runtime status

Device acceptance is pending. No native shortcut or playback observation has
been recorded for this change. Use an integrated candidate that contains the
feature commit and record its source revision, APK SHA-256, app version,
device model and Android API level. Reserve an exclusive slot for the
persistent `Videre_NerdVPN_Test` AVD (`emulator-5596`) with the integration
owner and preserve the AVD's app data and accounts.
[Repository Android instructions](../../AGENTS.md)

## Android acceptance steps

1. Start a long local track in a queue. Record the active queue occurrence,
   track, playing state, and position. Open **Settings → YT Music** and find
   **Android notification settings** and **Android battery settings**.
2. Open the notification shortcut. On API 26+ with a supported destination,
   Android should show notification settings for Videre. While the screen is
   open, verify that the same track keeps playing by listening or sampling the
   media session. Press Android Back and confirm YT Music settings return.
   Reopen the player and check that the same queue occurrence is active and
   its position advanced.
3. Repeat with the battery shortcut. On API 31+ where the device exposes the
   per-app battery screen, verify it shows Videre's battery or background
   controls. Check the same playback and Back behavior without changing a
   system setting during the check.
4. On a device where a dedicated screen is missing or blocked, verify that
   Videre explains the dedicated screen is unavailable. Choose **Cancel** and
   verify the Music settings remain usable. Open the shortcut again and choose
   **Open App info**. Verify that Android opens Videre's **App info**, and that
   Back returns to Music settings. If App info is also unavailable, check the
   guidance to open **Android Settings → Apps → Videre** manually. For each
   shortcut, record which destination or guidance appeared.
5. On Android TV, use a D-pad to reach each row from adjacent Music settings,
   activate it, and press Back. Confirm that focus is visible and navigation
   remains usable in Videre after a successful return or an unavailable
   destination.
