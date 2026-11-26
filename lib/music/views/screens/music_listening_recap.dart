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
import '../../../utils/motion.dart';
import '../../../utils/views/tv/components/tv_overscan.dart';
import '../../../videos/models/db/progress.dart';
import '../../models/music_listening_rankings.dart';
import '../../models/music_listening_recap.dart';
import '../../services/local_music_library.dart';
import '../../services/music_listening_history.dart';
import '../../services/music_recap_playback.dart';
import 'music.dart';
import '../components/music_listening_recap_card.dart';

const _recapSetting = 'music-listening-recap-enabled';
const _files = MethodChannel('videre/files');
const _fullYear = 0;

enum _ReplaySource { catalog, device }

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
  int _selectedMonth = _fullYear;
  bool _updatingConsent = false;
  int _consentRevision = 0;
  bool _saving = false;
  bool _replaying = false;

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
    _consentRevision++;
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

  Future<void> _save(
    MusicListeningRecapPeriod period,
    AppLocalizations locals,
  ) async {
    if (!_isCurrent || !_enabled || _saving || _updatingConsent) return;
    final recap = MusicListeningRecap.forPeriod(
      _history.events(),
      period,
      now: DateTime.now(),
    );
    if (recap == null) return;
    setState(() => _saving = true);
    try {
      final saved = await _files.invokeMethod<bool>('save', {
        'name': 'videre-music-recap-${period.fileSuffix}.json',
        'text': const JsonEncoder.withIndent('  ').convert(recap.toJson()),
      });
      if (saved == true) _notify(locals.musicListeningRecapSaved);
    } catch (_) {
      _notify(locals.musicListeningRecapSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<_ReplaySource?> _chooseReplaySource(AppLocalizations locals) =>
      showDialog<_ReplaySource>(
        context: context,
        useRootNavigator: false,
        animationStyle: AppMotion.dialogStyle(context),
        builder: (context) => SimpleDialog(
          title: Text(locals.musicHistoryChoosePlaybackSource),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, _ReplaySource.catalog),
              child: Text(locals.musicHistoryCatalogAndDownloads),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, _ReplaySource.device),
              child: Text(locals.musicHistoryDeviceFiles),
            ),
          ],
        ),
      );

  Future<void> _replay(
    MusicListeningRecapPeriod period,
    AppLocalizations locals,
  ) async {
    if (!_isCurrent || !_enabled || _replaying || _updatingConsent) return;
    final route = ModalRoute.of(context);
    final consentRevision = _consentRevision;
    final events = MusicListeningRecap.recordedInPeriod(
      _history.events(),
      period,
      now: DateTime.now(),
    ).toList();
    if (events.isEmpty) return;
    final eventIds = events.map((event) => event.id).toSet();
    var verifiedRevision = playbackHistoryRevision.value;
    bool current() {
      if (!_isCurrent ||
          !_enabled ||
          consentRevision != _consentRevision ||
          route?.isActive == false) {
        return false;
      }
      final revision = playbackHistoryRevision.value;
      if (revision != verifiedRevision) {
        final remaining = _history.events().map((event) => event.id).toSet();
        if (!remaining.containsAll(eventIds)) return false;
        verifiedRevision = revision;
      }
      return true;
    }

    setState(() => _replaying = true);
    try {
      final replay =
          await MusicRecapPlayback.resolve(events, _owner, isCurrent: current);
      if (!mounted ||
          !current() ||
          route?.isCurrent == false ||
          replay == null) {
        return;
      }
      if (replay.files.isEmpty && replay.videos.isEmpty) {
        _notify(locals.musicHistoryPlaybackUnavailable);
        return;
      }
      final source = replay.files.isEmpty
          ? _ReplaySource.catalog
          : replay.videos.isEmpty
              ? _ReplaySource.device
              : await _chooseReplaySource(locals);
      if (!mounted ||
          !current() ||
          route?.isCurrent == false ||
          source == null) {
        return;
      }
      if (replay.unavailable > 0) {
        _notify(locals.musicListeningRecapSkipped(replay.unavailable));
      }
      final queueTitle = locals.musicListeningRecapQueue(
        musicRecapPeriodLabel(MaterialLocalizations.of(context), period),
      );
      if (source == _ReplaySource.catalog) {
        await MusicScreen.playCollectionTracks(context, replay.videos,
            queueTitle: queueTitle,
            isCurrent: current,
            isTvQueueCurrent: current);
      } else {
        final usesDevice = replay.files.any((file) => file.deviceTrack != null);
        final library = LocalMusicLibrary.instance;
        bool deviceCurrent() =>
            current() &&
            (!usesDevice ||
                library.acceptsSessionSelection(replay.deviceSelection));
        if (!deviceCurrent()) {
          _notify(locals.musicHistoryPlaybackUnavailable);
          return;
        }
        await MusicScreen.playOnDeviceTracks(context, replay.files,
            queueTitle: queueTitle,
            retainQueueOrder: true,
            isCurrent: deviceCurrent);
      }
    } catch (_) {
      if (current()) _notify(locals.musicHistoryPlaybackUnavailable);
    } finally {
      if (mounted) setState(() => _replaying = false);
    }
  }

  MusicListeningRecap? _shareableRecap(MusicListeningRecapPeriod period) {
    if (!_isCurrent || !_enabled || _updatingConsent) return null;
    return MusicListeningRecap.forPeriod(
      _history.events(),
      period,
      now: DateTime.now(),
    );
  }

  void _previewCard(MusicListeningRecapPeriod period) {
    if (_shareableRecap(period) == null) return;
    showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (_) => BlocSelector<AppCubit, AppState, bool>(
        bloc: _app,
        selector: _isActive,
        builder: (context, _) => ListenableBuilder(
          listenable: _history.changes,
          builder: (context, _) => MusicListeningRecapCardDialog(
            recap: _shareableRecap(period),
            canShare: (preview) {
              final current = _shareableRecap(period);
              return current != null &&
                  jsonEncode(current.toJson()) == jsonEncode(preview.toJson());
            },
          ),
        ),
      ),
    );
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
    final lastMonth = year == now.year ? now.month : DateTime.december;
    final month = _selectedMonth <= lastMonth ? _selectedMonth : _fullYear;
    final period = MusicListeningRecapPeriod(
      year,
      month: month == _fullYear ? null : month,
    );
    final recap = MusicListeningRecap.forPeriod(events, period, now: now);
    final paused = _history.recordingPaused;
    final changingPeriodDisabled = _saving || _replaying;

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
      Wrap(
        spacing: 16,
        children: [
          Semantics(
            label: locals.musicListeningRecapYear,
            child: DropdownButton<int>(
              key: const ValueKey('music-listening-recap-year'),
              value: year,
              items: [
                for (final option in years)
                  DropdownMenuItem(
                    value: option,
                    child: Text(dates.formatYear(DateTime.utc(option))),
                  ),
              ],
              onChanged: changingPeriodDisabled || years.length == 1
                  ? null
                  : (value) => setState(() => _selectedYear = value),
            ),
          ),
          Semantics(
            label: locals.musicListeningRecapMonth,
            child: DropdownButton<int>(
              key: const ValueKey('music-listening-recap-month'),
              value: month,
              items: [
                DropdownMenuItem(
                  value: _fullYear,
                  child: Text(locals.musicListeningRecapFullYear),
                ),
                for (var option = 1; option <= lastMonth; option++)
                  DropdownMenuItem(
                    value: option,
                    child:
                        Text(dates.formatMonthYear(DateTime.utc(year, option))),
                  ),
              ],
              onChanged: changingPeriodDisabled
                  ? null
                  : (value) {
                      if (value != null) setState(() => _selectedMonth = value);
                    },
            ),
          ),
        ],
      ),
      if (paused) Text(locals.musicListeningPausedNotice),
      if (recap == null)
        Text(locals.musicListeningEmptyPeriod)
      else ...[
        Text(
          musicRecapSummary(locals, recap),
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(musicRecapRecordedDates(dates, locals, recap)),
        Text(locals.musicListeningRecapCoverage),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('music-listening-recap-replay'),
            onPressed: _replaying ? null : () => _replay(period, locals),
            icon: const Icon(Icons.play_arrow),
            label: Text(locals.musicListeningRecapPlay),
          ),
        ),
        ...highlights(recap.highlights(MusicListeningRankBy.song),
            locals.musicListeningRecapSongs),
        ...highlights(recap.highlights(MusicListeningRankBy.artist),
            locals.musicListeningRecapArtists),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            key: const ValueKey('music-listening-recap-save'),
            onPressed: _saving ? null : () => _save(period, locals),
            icon: const Icon(Icons.save_alt),
            label: Text(locals.musicListeningRecapSave),
          ),
        ),
        Text(locals.musicListeningRecapCopy),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            key: const ValueKey('music-listening-recap-preview'),
            onPressed: _saving ? null : () => _previewCard(period),
            icon: const Icon(Icons.image_outlined),
            label: Text(locals.musicListeningRecapCardPreview),
          ),
        ),
        if (period.month case final selectedMonth?) ...[
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text(
              locals.musicListeningRecapDailyActivity,
              style: theme.textTheme.titleMedium,
            ),
          ),
          for (final (index, plays) in recap.dailyPlays.indexed)
            Focus(
              canRequestFocus: isTv,
              child: Builder(
                builder: (context) => ListTile(
                  key: ValueKey('music-listening-recap-day-${index + 1}'),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  tileColor: isTv && Focus.of(context).hasFocus
                      ? theme.colorScheme.secondaryContainer
                      : null,
                  title: Text(
                    dates.formatMediumDate(
                      DateTime.utc(period.year, selectedMonth, index + 1),
                    ),
                  ),
                  trailing: Text(locals.musicListeningPlayCount(plays)),
                ),
              ),
            ),
        ],
      ],
    ];
  }
}
