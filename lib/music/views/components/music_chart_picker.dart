import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_charts.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<String?> showMusicChartPicker(BuildContext context,
    {required String browsingCountry}) {
  final charts = [
    ...musicCharts.where((chart) => chart.countryCode == browsingCountry),
    ...musicCharts.where((chart) => chart.countryCode != browsingCountry),
  ];
  final locals = AppLocalizations.of(context)!;
  return showDialog<String>(
    context: context,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) => Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: SimpleDialog(
        title: Text(locals.musicTopCharts),
        children: [
          for (final (index, chart) in charts.indexed)
            ListTile(
              autofocus: index == 0,
              leading: Icon(chart.type == MusicChartType.songs
                  ? Icons.music_note_outlined
                  : Icons.music_video_outlined),
              title: Text(chart.countryCode == null
                  ? locals.musicChartWorldwide
                  : getCountryFromCode(chart.countryCode!).name),
              subtitle: Text(chart.type == MusicChartType.songs
                  ? locals.musicChartTopSongs
                  : locals.musicChartTopVideos),
              onTap: () => Navigator.of(context).pop(chart.playlistId),
            ),
        ],
      ),
    ),
  );
}
