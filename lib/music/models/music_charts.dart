enum MusicChartType { songs, musicVideos }

typedef MusicChart = ({
  String? countryCode,
  String playlistId,
  MusicChartType type,
});

// Public playlists from YouTube Music Global Charts (UCrKZcyOJVWnJ60zM1XWllNw).
// Only the IDs are bundled. The selected Invidious instance supplies each
// playlist's current tracks using its ordinary public playlist route.
const musicCharts = <MusicChart>[
  (
    countryCode: null,
    playlistId: 'PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i',
    type: MusicChartType.songs,
  ),
  (
    countryCode: null,
    playlistId: 'PL4fGSI1pDJn5kI81J1fYWK5eZRl1zJ5kM',
    type: MusicChartType.musicVideos,
  ),
  (
    countryCode: 'BR',
    playlistId: 'PL4fGSI1pDJn4Gs2meaJRo9O8PNYvhjHIg',
    type: MusicChartType.musicVideos,
  ),
  (
    countryCode: 'IN',
    playlistId: 'PL4fGSI1pDJn40WjZ6utkIuj2rNg-7iGsq',
    type: MusicChartType.musicVideos,
  ),
  (
    countryCode: 'JP',
    playlistId: 'PL4fGSI1pDJn4-UIb6RKHdxam-oAUULIGB',
    type: MusicChartType.songs,
  ),
  (
    countryCode: 'JP',
    playlistId: 'PL4fGSI1pDJn5FhDrWnRp2NLzJCoPliNgT',
    type: MusicChartType.musicVideos,
  ),
  (
    countryCode: 'MX',
    playlistId: 'PL4fGSI1pDJn5cDciLg1q9tabl7gzBZWOp',
    type: MusicChartType.musicVideos,
  ),
  (
    countryCode: 'KR',
    playlistId: 'PL4fGSI1pDJn6jXS_Tv_N9B8Z0HTRVJE0m',
    type: MusicChartType.songs,
  ),
  (
    countryCode: 'SG',
    playlistId: 'PL4fGSI1pDJn6NXctD9ORkRNLT7DwyhIOw',
    type: MusicChartType.musicVideos,
  ),
  (
    countryCode: 'TR',
    playlistId: 'PL4fGSI1pDJn6rnJKpaAkK1XK8QUfa9KqP',
    type: MusicChartType.musicVideos,
  ),
  (
    countryCode: 'US',
    playlistId: 'PL4fGSI1pDJn69On1f-8NAvX_CYlx7QyZc',
    type: MusicChartType.musicVideos,
  ),
];
