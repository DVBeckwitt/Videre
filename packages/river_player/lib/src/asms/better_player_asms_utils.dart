import 'dart:convert';
import 'dart:io';

import 'package:river_player/src/core/better_player_utils.dart';
import 'package:river_player/src/dash/better_player_dash_utils.dart';
import 'package:river_player/src/hls/better_player_hls_utils.dart';

import 'better_player_asms_data_holder.dart';

///Base helper class for ASMS parsing.
class BetterPlayerAsmsUtils {
  static const String _hlsExtension = "m3u8";
  static const String _dashExtension = "dash";

  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  ///Check if given url is HLS / DASH-type data source.
  static bool isDataSourceAsms(String url) =>
      isDataSourceHls(url) || isDataSourceDash(url);

  ///Check if given url is HLS-type data source.
  static bool isDataSourceHls(String url) => url.contains(_hlsExtension);

  ///Check if given url is DASH-type data source.
  static bool isDataSourceDash(String url) => url.contains(_dashExtension);

  ///Parse playlist based on type of stream.
  static Future<BetterPlayerAsmsDataHolder> parse(
      String data, String masterPlaylistUrl,
      {bool loadSubtitles = true}) async {
    return isDataSourceDash(masterPlaylistUrl)
        ? BetterPlayerDashUtils.parse(data, masterPlaylistUrl)
        : BetterPlayerHlsUtils.parse(data, masterPlaylistUrl,
            loadSubtitles: loadSubtitles);
  }

  ///Request data from given uri along with headers. May return null if resource
  ///is not available or on error.
  static Future<String?> getDataFromUrl(
    String url, [
    Map<String, String?>? headers,
  ]) async {
    try {
      final request = await _httpClient.getUrl(Uri.parse(url));
      headers?.forEach((name, value) => request.headers.add(name, value!));
      final response = await request.close();
      return await response.transform(const Utf8Decoder()).join();
    } catch (exception) {
      BetterPlayerUtils.log("GetDataFromUrl failed: ${exception.runtimeType}");
      return null;
    }
  }
}
