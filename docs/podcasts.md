# Podcasts

Open **Music → Library → Podcasts → Add podcast** and paste the publisher's RSS
feed link. The subscription and episode list are saved in the current local
profile. Open a podcast to choose an episode. Use **Refresh** to update its list;
opening Podcasts does not automatically contact a publisher.

When a publisher includes episode notes, the episode list shows a short
preview. Choose **Description** on the episode to read the saved notes, including
from **Downloaded episodes**. Videre shows the text without loading embedded
media. If an older subscription used a description field Videre did not read,
use **Refresh** to save the notes from the feed.

Podcast playback has its own audio source and uses Videre's Android media
controls. The compact player remains available while browsing. Open it for
seeking, playback speed, back 15 seconds, and forward 30 seconds. Starting a
podcast stops video/music playback; starting a video or song stops the podcast.
Changing profiles stops playback and active podcast downloads.

Episodes remember your listening position in the current profile. Select the
episode again to continue where you stopped, including after restarting Videre
or switching between streaming and its downloaded copy. Finished episodes start
from the beginning. Progress stays on this device and is not sent to publishers.
Videre keeps positions for the 2,000 most recently updated episodes. Progress
saves on pause, seek, and stop, and every five seconds during playback; an abrupt
process termination may lose the last few seconds.

## Offline listening

Use an episode's **Download** button, then open **Downloaded episodes** to listen
from the saved file. Completed downloads and their episode labels survive app
restarts and feed refreshes. Unsubscribing keeps downloaded episodes; their
separate remove button deletes the saved audio. Missing or incomplete files are
never silently streamed from the Downloaded episodes view.

Downloads use private app storage and respect the existing **Download on Wi-Fi
only** preference. One episode downloads at a time. Cancel stops the transfer;
retry starts a fresh copy to avoid combining bytes from different dynamically
served versions of an episode. A transfer requires the app process to remain
running; completed downloads remain available offline. Uninstalling the app
removes its private audio files.

## Connections and supported feeds

Feed refresh and streaming/downloads connect directly to the publisher's feed
and audio hosts, using the configured network proxy. They do not use Invidious
accounts, Google login, YouTube APIs, server subscription sync, or remote watch
history. Known Google/YouTube service domains, including FeedBurner, are blocked
before connections and on redirects. Use an independent publisher feed when a
Google-hosted feed is blocked. Exported/request URLs are never used for artwork;
podcasts display a local icon.

Supported input is a UTF-8 RSS 2.0 feed with audio enclosure URLs. Feed reads are
limited to 4 MiB and the first 1,000 supported audio episodes. The local library
holds up to 100 feeds and 10 MiB of metadata. Each download is limited to 1 GiB,
with up to 1,000 completed download records and 5 MiB of download metadata.
The feed's reported audio length is advisory; actual HTTP transfer lengths are
validated before a file becomes playable offline.

Subscriptions are stored locally per profile. There is no automatic feed
refresh, auto-download, account sync, or OPML import/export in this version.
Podcast subscriptions and listening positions are not yet included in Videre's
backup exports.
