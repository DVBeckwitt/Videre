import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/components/music_voice_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Adds voice input to an existing editable collection filter.
class MusicVoiceFilter extends StatefulWidget {
  const MusicVoiceFilter({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onQueryChanged,
    required this.scope,
    required this.builder,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onQueryChanged;
  final Object scope;
  final Widget Function(Widget? microphone) builder;

  @override
  State<MusicVoiceFilter> createState() => _MusicVoiceFilterState();
}

class _MusicVoiceFilterState extends State<MusicVoiceFilter> {
  bool _available = false;
  bool _pending = false;
  bool _recognizing = false;
  bool _retired = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkAvailability());
  }

  Future<void> _checkAvailability() async {
    if (await musicVoiceInputAvailable() && mounted) {
      setState(() => _available = true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.of(context);
    final routeCurrent = ModalRoute.isCurrentOf(context) != false;
    // Our own consent dialog covers the route before recognition starts.
    if (_pending && (!visible || (_recognizing && !routeCurrent))) {
      _retired = true;
    }
  }

  @override
  void didUpdateWidget(MusicVoiceFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope ||
        oldWidget.controller != widget.controller) {
      _retired = true;
    }
  }

  Future<void> _start() async {
    if (_pending) return;
    final app = context.read<AppCubit>();
    final session = app.state;
    final route = ModalRoute.of(context);
    final controller = widget.controller;
    final draft = controller.text;

    bool current() {
      if (!mounted ||
          _retired ||
          !TickerMode.of(context) ||
          route?.isCurrent == false ||
          app.isClosed) {
        return false;
      }
      final active = app.state;
      return active.profileId == session.profileId &&
          active.sessionRevision == session.sessionRevision &&
          active.server == session.server &&
          !active.globalLoading &&
          !active.sessionRecoveryRequired;
    }

    void checkDraft() {
      if (controller.text != draft) _retired = true;
    }

    setState(() {
      _pending = true;
      _retired = false;
    });
    controller.addListener(checkDraft);
    try {
      final transcript = await requestMusicVoiceInput(
        context,
        isCurrent: current,
        collectionFilter: true,
        onConsent: () {
          _recognizing = true;
          widget.focusNode.unfocus();
        },
      );
      if (transcript == null || !current()) return;
      controller.value = TextEditingValue(
        text: transcript,
        selection: TextSelection.collapsed(offset: transcript.length),
      );
      widget.onQueryChanged();
    } finally {
      controller.removeListener(checkDraft);
      _recognizing = false;
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(
        _available
            ? IconButton(
                tooltip: AppLocalizations.of(context)!.musicVoiceSearch,
                onPressed: _pending ? null : _start,
                icon: const Icon(Icons.mic),
              )
            : null,
      );
}
