These reduced fixtures were captured from unauthenticated public YouTube Music
search/browse responses on 2026-11-08, using the repository's Dart 3.9.2 SDK.

- `songs.json`: first two results for `Daft Punk Get Lucky`.
- `albums.json`: first two results for `Daft Punk Random Access Memories`.
- `album.json`: header and all 13 ordered tracks of `MPREb_K8qWMWVqXGi`.
- `artists.json`, `playlists_search.json`: first two artist/public playlist
  search results for `Daft Punk`.
- `artist.json`: Daft Punk's header, two top songs, one album and one single
  preview, and an unrelated featured-on shelf. Its biography is replaced with
  fixture-only text; the original includes a lengthy Wikipedia passage.
- `artist_albums.json`, `artist_singles.json`: first three cards from the full
  release grids. The live grids contained 11 albums and 26 singles, while their
  artist-page previews contained 10 each. The fixtures retain both browse ID and
  params so tests verify that full shelves are requested.

Only metadata fields used by the adapter remain. Request keys, visitor identifiers,
cookies, tracking data, menus and recommendations are omitted. This is an
unofficial API and these fixtures establish the observed response shape, not a
guarantee of future compatibility. The adapter's filters were compared with
`dart_ytmusic_api` 1.3.7; its singleton transport and album track reordering were
not adopted.
