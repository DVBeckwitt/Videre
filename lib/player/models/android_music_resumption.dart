import '../../downloads/services/explicit_music_download.dart';

enum AndroidMusicResumeSource { device, download, online }

/// Origin proof for the mounted occurrence of the active Music checkpoint.
/// Do not store stream URLs, credentials, or device document URIs here.
class AndroidMusicResumption {
  static final _digest = RegExp(r'^[a-f0-9]{64}$');

  final String occurrence;
  final AndroidMusicResumeSource source;
  final String identity;
  final bool authenticated;

  const AndroidMusicResumption(this.occurrence, this.source, this.identity,
      {this.authenticated = false});

  Map<String, Object> toJson() => {
        'occurrence': occurrence,
        'source': source.name,
        'identity': identity,
        if (authenticated) 'authenticated': true,
      };

  static AndroidMusicResumption? tryParse(Object? json) {
    if (json
        case {
          'occurrence': final String occurrence,
          'source': final String sourceName,
          'identity': final String identity,
        } when occurrence.isNotEmpty && occurrence.length <= 512) {
      final source = AndroidMusicResumeSource.values.asNameMap()[sourceName];
      if (source == null) return null;
      final authenticated = json['authenticated'] == true;
      final validIdentity = switch (source) {
        AndroidMusicResumeSource.download =>
          pinnedMusicDownloadFileProof(identity) != null,
        _ => _digest.stringMatch(identity) == identity,
      };
      if (validIdentity &&
          (!authenticated || source == AndroidMusicResumeSource.online)) {
        return AndroidMusicResumption(occurrence, source, identity,
            authenticated: authenticated);
      }
    }
    return null;
  }
}
