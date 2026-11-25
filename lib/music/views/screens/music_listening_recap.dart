import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../settings/models/db/settings.dart';
import '../../../utils.dart' show selectKeys;
import '../../../utils/interfaces/db.dart';
import '../../../utils/views/tv/components/tv_overscan.dart';
import '../../models/music_listening_rankings.dart';
import '../../models/music_listening_recap.dart';
import '../../services/music_listening_history.dart';

const _recapSetting = 'music-listening-recap-enabled';
const _files = MethodChannel('videre/files');

class MusicListeningRecapPage extends StatefulWidget {
  const MusicListeningRecapPage({super.key});

  @override
  State<MusicListeningRecapPage> createState() =>
      _MusicListeningRecapPageState();
}

class _MusicListeningRecapPageState extends State<MusicListeningRecapPage> {
  late final AppCubit _app;
  late final AppState _session;
  late final IDbClient _database;
  late final IDbClient _owner;
  late final MusicListeningHistory _history;
  int? _selectedYear;
  bool _updatingConsent = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppCubit>();
    _session = _app.state;
    _database = db;
    _owner = _database.forProfile(_session.profileId);
    _history = MusicListeningHistory.forProfile(_database, _session.profileId);
  }

  bool _isActive(AppState state) =>
      identical(db, _database) &&
      _database.profileId == _session.profileId &&
      state.profileId == _session.profileId &&
      state.sessionRevision == _session.sessionRevision &&
      state.server == _session.server &&
      !state.globalLoading &&
      !state.sessionRecoveryRequired;

  bool get _isCurrent => mounted && !_app.isClosed && _isActive(_app.state);
  bool get _enabled => _owner.getSettings(_recapSetting)?.value == 'true';

  void _notify(String message) {
    if (_isCurrent) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _setEnabled(bool enabled, AppLocalizations locals) async {
    if (!_isCurrent || _updatingConsent || _saving) return;
    setState(() => _updatingConsent = true);
    try {
      await _owner
          .saveSetting(SettingsValue(_recapSetting, enabled.toString()));
    } catch (_) {
      _notify(locals.musicListeningRecapConsentFailed);
    } finally {
      if (mounted) setState(() => _updatingConsent = false);
    }
  }

  Future<void> _save(int year, AppLocalizations locals) async {
    if (!_isCurrent || !_enabled || _saving || _updatingConsent) return;
    final recap = MusicListeningRecap.forYear(_history.events(), year,
        now: DateTime.now());
    if (recap == null) return;
    setState(() => _saving = true);
    try {
      final saved = await _files.invokeMethod<bool>('save', {
        'name': 'videre-music-recap-$year.json',
        'text': const JsonEncoder.withIndent('  ').convert(recap.toJson()),
      });
      if (saved == true) _notify(locals.musicListeningRecapSaved);
    } catch (_) {
      _notify(locals.musicListeningRecapSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = context.select((AppCubit app) => _isActive(app.state));
    final locals = AppLocalizations.of(context)!;
    final unavailable =
        Center(child: Text(locals.musicListeningRecapUnavailable));
    final body = active
        ? ListenableBuilder(
            listenable: _history.changes,
            builder: (context, _) =>
                _isCurrent ? _buildRecap(context, locals) : unavailable,
          )
        : unavailable;
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(locals.musicListeningRecap)),
        body:
            SafeArea(top: false, child: isTv ? TvOverscan(child: body) : body),
      ),
    );
  }

  Widget _buildRecap(BuildContext context, AppLocalizations locals) {
    final enabled = _enabled && !_updatingConsent;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          key: const ValueKey('music-listening-recap-consent'),
          contentPadding: EdgeInsets.zero,
          autofocus: isTv,
          title: Text(locals.musicListeningRecapConsent),
          subtitle: Text(locals.musicListeningRecapPrivacy),
          value: enabled,
          onChanged: _updatingConsent || _saving
              ? null
              : (value) => _setEnabled(value, locals),
        ),
        if (enabled) ..._buildReport(context, locals),
      ],
    );
  }

  List<Widget> _buildReport(BuildContext context, AppLocalizations locals) {
    final theme = Theme.of(context);
    final dates = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final events = _history.events();
    final years = MusicListeningRecap.availableYears(events, now: now);
    final year = years.contains(_selectedYear) ? _selectedYear! : years.first;
    final recap = MusicListeningRecap.forYear(events, year, now: now);
    final paused = _history.recordingPaused;

    List<Widget> highlights(Iterable<MusicListeningRank> rows, String heading) {
      if (rows.isEmpty) return const [];
      return [
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(heading, style: theme.textTheme.titleMedium),
        ),
        for (final row in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(row.title ?? locals.musicListeningUnknownTitle),
            subtitle: row.subtitle == null ? null : Text(row.subtitle!),
            trailing: Text(locals.musicListeningPlayCount(row.plays)),
          ),
      ];
    }

    return [
      const Divider(),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          label: locals.musicListeningRecapYear,
          child: DropdownButton<int>(
            key: const ValueKey('music-listening-recap-year'),
            value: year,
            items: [
              for (final option in years)
                DropdownMenuItem(
                    value: option,
                    child: Text(dates.formatYear(DateTime(option)))),
            ],
            onChanged: _saving || years.length == 1
                ? null
                : (value) => setState(() => _selectedYear = value),
          ),
        ),
      ),
      if (paused) Text(locals.musicListeningPausedNotice),
      if (recap == null)
        Text(locals.musicListeningEmptyPeriod)
      else ...[
        Text(
          locals.musicListeningSummary(
            locals.musicListeningPlayCount(recap.rankings.plays),
            locals.musicTrackCount(recap.songCount),
          ),
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(DateUtils.isSameDay(recap.firstPlay, recap.lastPlay)
            ? locals.musicListeningRecapRecordedOn(
                dates.formatFullDate(recap.firstPlay))
            : locals.musicListeningRecapRecordedBetween(
                dates.formatFullDate(recap.firstPlay),
                dates.formatFullDate(recap.lastPlay))),
        Text(locals.musicListeningRecapCoverage),
        ...highlights(recap.highlights(MusicListeningRankBy.song),
            locals.musicListeningRecapSongs),
        ...highlights(recap.highlights(MusicListeningRankBy.artist),
            locals.musicListeningRecapArtists),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            key: const ValueKey('music-listening-recap-save'),
            onPressed: _saving ? null : () => _save(year, locals),
            icon: const Icon(Icons.save_alt),
            label: Text(locals.musicListeningRecapSave),
          ),
        ),
        Text(locals.musicListeningRecapCopy),
      ],
    ];
  }
}
