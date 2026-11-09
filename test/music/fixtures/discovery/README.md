Reduced anonymous public YouTube Music browse responses captured 2026-11-08.
Only parser-required metadata is retained. Configuration, visitor identifiers,
cookies, tracking, playback and personal/account data were never saved. Country
menu entity keys are replaced with `fixture-country-CODE` on both sides of the
menu/mutation relationship; these are not live identifiers.

- `new_releases.json`: first three cards from the dedicated
  `FEmusic_new_releases_albums` grid, which returned 151 albums/singles. This is
  not search or a personalized Home feed. Consecutive requests can differ.
- `charts_global.json`, `charts_us.json`: country menu and two cards per shelf.
  Global returned two chart playlists and 40 artist cards; US returned four
  video-chart playlists, eight genre-chart playlists, 50 albums, 40 artists,
  and 50 podcasts. Albums and podcasts must not become chart artists. Artist
  rankings are deliberately not represented; public chart-card order is not a
  supported numerical ranking contract. Country labels come from the menu,
  linked to validated country codes in framework mutations.
- `moods.json`: first two public entries each from Moods & moments (13 total)
  and Genres (27 total). The parser excludes the personalized For you group.
- `mood_playlists.json`: first two cards from each of the first two Chill
  carousels, originally 17 carousels. Editorial playlist IDs and artwork remain.

Endpoint and renderer interpretation was checked against ytmusicapi 1.12.3:
https://github.com/sigma67/ytmusicapi/blob/1.12.3/ytmusicapi/mixins/explore.py
https://github.com/sigma67/ytmusicapi/blob/1.12.3/ytmusicapi/mixins/charts.py
https://ytmusicapi.readthedocs.io/en/stable/reference/explore.html

These are unofficial public endpoints. The fixtures establish observed response
shapes, not future service compatibility, availability, or native playback.
