/// Official YouTube services and the image/media hosts used by its responses.
/// Match host boundaries only: an Invidious URL may legitimately contain a
/// Googlevideo host in its signed query without contacting that host directly.
bool isOfficialYoutubeHost(String input) {
  // IDNA treats these separators as an ASCII full stop. Normalize before
  // comparing even when a caller has not yet passed through its HTTP parser.
  final host = input
      .toLowerCase()
      .replaceAll(RegExp('[\u3002\uff0e\uff61]'), '.')
      .replaceFirst(RegExp(r'\.+$'), '');
  return const [
    'youtube',
    'youtube.com',
    'youtu.be',
    'yt.be',
    'youtube-nocookie.com',
    'youtubeeducation.com',
    'youtubekids.com',
    // Shared API dispatch/batch endpoints can select YouTube in their body.
    // Videre has no dependency on any Google API, so do not infer safety from
    // a path that happens not to contain the word "youtube".
    'googleapis.com',
    'googlevideo.com',
    'ytimg.com',
    'ggpht.com',
    'googleusercontent.com',
    'gstatic.com',
  ].any((root) => host == root || host.endsWith('.$root'));
}

bool isOfficialYoutubeUrl(Uri uri) => isOfficialYoutubeHost(uri.host);
