import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/videos/models/dearrow.dart';
import 'package:logging/logging.dart';

import '../videos/models/video.dart';

var log = Logger('Video post process');
const privateVideoString = "[Private video]";

Future<List<Video>> postProcessVideos(List<Video> toProcess,
    {bool enrichResults = true}) async {
  try {
    int start = DateTime.now().millisecondsSinceEpoch;
    List<Video> videos = toProcess
        .where((element) => element.title != privateVideoString)
        .toList();

    videos = await VideoFilter.filterVideos(videos);
    if (enrichResults) videos = await DeArrow.processVideos(videos);

    log.fine(
        "Video post-processing took ${DateTime.now().millisecondsSinceEpoch - start}ms for ${toProcess.length} videos");
    return videos;
  } catch (err) {
    log.severe('Issue while running post process', err);
    return toProcess;
  }
}
