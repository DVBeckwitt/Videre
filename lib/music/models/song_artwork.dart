import 'package:clipious/utils/models/image_object.dart';

final _catalogImagePath = RegExp(r'^/[a-zA-Z0-9_-]+(?:=[a-zA-Z0-9_-]+)?$');
final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _stockImagePath = RegExp(
    r'^/(vi|vi_webp)/([A-Za-z0-9_-]{11})/(maxres(?:default)?|sddefault|hq720|hqdefault|mqdefault|default|[0-3])\.(jpg|webp)$');
final _absoluteImagePath = RegExp(r'^https?://[^/?#@\\]+(/[^?#]*)');

/// Original catalog artwork stored on a song by older Music versions. Stock
/// Invidious supplies video thumbnails in a separate field. A generic proxy
/// path or square video image cannot identify an album cover.
List<ImageObject> songCovers(List<ImageObject> catalogImages) =>
    catalogImages.where((image) {
      final uri = Uri.tryParse(image.url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.hasPort ||
          uri.userInfo.isNotEmpty ||
          !const {
            'lh3.googleusercontent.com',
            'yt3.googleusercontent.com',
            'yt3.ggpht.com',
          }.contains(uri.host)) {
        return false;
      }
      // The song and album catalog stored an opaque image ID in one segment.
      // Renderers resolve these originals through the selected instance.
      return _catalogImagePath.hasMatch(uri.path);
    }).toList(growable: false);

/// A saved URL can name an old instance or a CDN. Only the stock route, video
/// ID and rendition survive. The selected instance supplies the request origin.
List<ImageObject> stockSongThumbnails(String videoId, List<ImageObject> images,
    {bool artTrack = false, String? instanceUrl}) {
  if (_videoId.stringMatch(videoId) != videoId) return const [];
  final instance = instanceUrl == null ? null : Uri.tryParse(instanceUrl);
  final basePath = instance != null &&
          instance.hasAuthority &&
          const {'https', 'http'}.contains(instance.scheme)
      ? instance.path.replaceFirst(RegExp(r'/+$'), '')
      : '';
  final candidates = <String, ImageObject>{};
  for (final image in images.take(16)) {
    final url = image.url;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        url.contains('\\') ||
        (uri.hasScheme && !const {'http', 'https'}.contains(uri.scheme)) ||
        (uri.hasAuthority && (!uri.hasScheme || uri.host.isEmpty)) ||
        (uri.hasScheme && !uri.hasAuthority)) continue;
    final rawPath = uri.hasAuthority
        ? _absoluteImagePath.firstMatch(url)?.group(1)
        : url.split(RegExp(r'[?#]')).first;
    if (rawPath != uri.path) continue;
    var path = uri.path;
    if (basePath.isNotEmpty &&
        path.startsWith('$basePath/') &&
        (!uri.hasAuthority || uri.origin == instance!.origin)) {
      path = path.substring(basePath.length);
    }
    final match = _stockImagePath.firstMatch(path);
    if (match == null || match[2] != videoId) continue;
    final name = match[3]!;
    final portable = '/vi/$videoId/$name.jpg';
    candidates.putIfAbsent(portable,
        () => ImageObject(image.quality, portable, image.width, image.height));
  }
  if (artTrack) {
    // The official Art Track visual contains the release image. Prefer its
    // full-size stills over tiny time-based frames when stock supplies both.
    final fullSize = [
      for (final name in ['maxresdefault', 'maxres', 'sddefault', 'hqdefault'])
        if (candidates['/vi/$videoId/$name.jpg'] case final image?) image,
    ];
    return ImageObject.withFallback(fullSize, [
      for (final image in candidates.values)
        if (!fullSize.contains(image)) image,
    ]);
  }
  return candidates.values.toList(growable: false);
}

List<ImageObject> displaySongThumbnails(
    String videoId, List<ImageObject> catalog, List<ImageObject> frames,
    {bool artTrack = false, String? instanceUrl}) {
  return ImageObject.withFallback(
      songCovers(catalog),
      stockSongThumbnails(videoId, frames,
          artTrack: artTrack, instanceUrl: instanceUrl));
}
