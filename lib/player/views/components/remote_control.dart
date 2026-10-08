import 'dart:async';
import 'dart:io';

import 'package:clipious/player/remote_control.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

final _session = _RemoteSession();

// Keep the opt-in session alive when the dialog closes so the TV stays watchable.
class _RemoteSession extends ChangeNotifier with WidgetsBindingObserver {
  RemoteReceiver? receiver;
  RemoteClient? client;
  List<String> addresses = [];
  StreamSubscription<PlayerState>? _playerSubscription;
  Timer? _expiry;
  int _generation = 0;

  bool get active => receiver != null || client != null;
  bool get _foreground => switch (WidgetsBinding.instance.lifecycleState) {
        AppLifecycleState.paused ||
        AppLifecycleState.hidden ||
        AppLifecycleState.detached =>
          false,
        _ => true,
      };

  void _observe() {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> receive(PlayerCubit player) async {
    await stopReceiving();
    final generation = _generation;
    _observe();
    final next = await RemoteReceiver.start(
      onCommand: (command) async {
        if (player.isClosed ||
            receiver == null ||
            !_foreground ||
            generation != _generation) return;
        switch (command.action) {
          case 'load':
            await player.playRemoteVideo(
                command.videoId!, command.position, command.playing,
                isActive: () =>
                    receiver?.paired == true &&
                    _foreground &&
                    generation == _generation &&
                    !player.isClosed);
          case 'play':
            player.play();
          case 'pause':
            player.pause();
        }
      },
      onChanged: notifyListeners,
    );
    if (generation != _generation || !_foreground || player.isClosed) {
      await next.close();
      return;
    }
    receiver = next;
    _playerSubscription = player.stream.listen((_) {}, onDone: stopReceiving);
    try {
      addresses = await next.localAddresses();
    } catch (_) {
      await stopReceiving();
      rethrow;
    }
    if (generation != _generation) return;
    _expiry = Timer(const Duration(minutes: 5), () {
      if (receiver?.paired == false) stopReceiving();
    });
    notifyListeners();
  }

  Future<void> stopReceiving() async {
    _generation++;
    final previous = receiver;
    receiver = null;
    addresses = [];
    _expiry?.cancel();
    await _playerSubscription?.cancel();
    _playerSubscription = null;
    await previous?.close();
    if (!active) WidgetsBinding.instance.removeObserver(this);
    notifyListeners();
  }

  Future<void> connect(String address, String code) async {
    final generation = _generation;
    _observe();
    final next = RemoteClient(address);
    try {
      await next.pair(code);
    } catch (_) {
      next.close();
      rethrow;
    }
    if (!_foreground || generation != _generation) {
      try {
        await next.send(const RemoteCommand('disconnect'));
      } finally {
        next.close();
      }
      return;
    }
    client?.close();
    client = next;
    _observe();
    notifyListeners();
  }

  Future<void> disconnect() async {
    final previous = client;
    client = null;
    try {
      await previous?.send(const RemoteCommand('disconnect'));
    } finally {
      previous?.close();
      if (!active) WidgetsBinding.instance.removeObserver(this);
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      stopReceiving();
      disconnect().catchError((_) {});
    }
  }
}

class RemoteControlButton extends StatelessWidget {
  final PlayerCubit player;

  const RemoteControlButton({super.key, required this.player});

  static Future<void> show(BuildContext context, PlayerCubit player,
          {bool startReceiving = false}) =>
      showDialog<void>(
        context: context,
        builder: (context) => _RemoteControlDialog(
            player: player, startReceiving: startReceiving),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _session,
        builder: (context, _) => IconButton(
          tooltip: AppLocalizations.of(context)!.remoteControlTitle,
          icon: Icon(_session.active ? Icons.cast_connected : Icons.cast),
          onPressed: () => show(context, player),
        ),
      );
}

class _RemoteControlDialog extends StatefulWidget {
  final PlayerCubit player;
  final bool startReceiving;

  const _RemoteControlDialog(
      {required this.player, this.startReceiving = false});

  @override
  State<_RemoteControlDialog> createState() => _RemoteControlDialogState();
}

class _RemoteControlDialogState extends State<_RemoteControlDialog> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    if (widget.startReceiving) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(() => _session.receive(widget.player));
      });
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, [String? success]) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = success);
    } catch (error) {
      if (mounted) {
        final locals = AppLocalizations.of(context)!;
        final code = switch (error) {
          FormatException() => error.message,
          HttpException() => error.message,
          _ => '',
        };
        setState(() => _message = switch (code) {
              'remoteInvalidAddress' => locals.remoteInvalidAddress,
              'remoteInvalidCode' => locals.remoteInvalidCode,
              'remoteExpired' => locals.remoteExpired,
              'remoteBusy' => locals.remoteBusy,
              'remoteCommandFailed' => locals.remoteCommandFailed,
              _ => locals.remoteConnectionFailed,
            });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final locals = AppLocalizations.of(context)!;
          final receiver = _session.receiver;
          final client = _session.client;
          return AlertDialog(
            title: Text(locals.remoteControlTitle),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(locals.remoteInstructions),
                    const SizedBox(height: 16),
                    if (receiver == null)
                      FilledButton.tonalIcon(
                        autofocus: true,
                        onPressed: _busy
                            ? null
                            : () => _run(() => _session.receive(widget.player)),
                        icon: const Icon(Icons.tv),
                        label: Text(locals.remoteReceiveHere),
                      )
                    else ...[
                      Text(
                          receiver.paired
                              ? locals.remotePhoneConnected
                              : receiver.pairingAvailable
                                  ? locals.remotePairInstructions
                                  : locals.remoteDisconnected,
                          style: Theme.of(context).textTheme.titleMedium),
                      if (receiver.pairingAvailable) ...[
                        SelectableText(_session.addresses.isEmpty
                            ? locals.remoteNoAddress
                            : _session.addresses.join('\n')),
                        const SizedBox(height: 8),
                        SelectableText(receiver.code,
                            style: Theme.of(context).textTheme.headlineMedium),
                        Text(locals.remoteCodeExpiry),
                      ],
                      if (!receiver.paired && !receiver.pairingAvailable)
                        FilledButton.tonal(
                          onPressed: _busy
                              ? null
                              : () =>
                                  _run(() => _session.receive(widget.player)),
                          child: Text(locals.remoteRestart),
                        ),
                      TextButton.icon(
                        onPressed:
                            _busy ? null : () => _run(_session.stopReceiving),
                        icon: const Icon(Icons.stop),
                        label: Text(locals.remoteStop),
                      ),
                    ],
                    const Divider(height: 32),
                    if (client == null) ...[
                      TextField(
                        controller: _address,
                        autocorrect: false,
                        decoration: InputDecoration(
                            labelText: locals.remoteAddress,
                            hintText: '192.168.1.10:12345'),
                      ),
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration:
                            InputDecoration(labelText: locals.remoteCode),
                      ),
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => _session.connect(
                                    _address.text, _code.text.trim()),
                                locals.remoteConnected),
                        child: Text(locals.remoteConnect),
                      ),
                    ] else ...[
                      Text(locals.remoteConnectedTo(client.address.authority)),
                      FilledButton.icon(
                        onPressed: _busy ||
                                widget.player.state.currentlyPlaying == null
                            ? null
                            : () => _run(() async {
                                  final state = widget.player.state;
                                  await client.send(RemoteCommand('load',
                                      videoId: state.currentlyPlaying!.videoId,
                                      position: state.position.inSeconds,
                                      playing: state.isPlaying));
                                  widget.player.pause();
                                }, locals.remoteSent),
                        icon: const Icon(Icons.send),
                        label: Text(locals.remoteSend),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: locals.remotePlay,
                            onPressed: _busy
                                ? null
                                : () => _run(() =>
                                    client.send(const RemoteCommand('play'))),
                            icon: const Icon(Icons.play_arrow),
                          ),
                          IconButton(
                            tooltip: locals.remotePause,
                            onPressed: _busy
                                ? null
                                : () => _run(() =>
                                    client.send(const RemoteCommand('pause'))),
                            icon: const Icon(Icons.pause),
                          ),
                        ],
                      ),
                      TextButton(
                        onPressed:
                            _busy ? null : () => _run(_session.disconnect),
                        child: Text(locals.remoteDisconnect),
                      ),
                    ],
                    if (_busy) const LinearProgressIndicator(),
                    if (_message != null) ...[
                      const SizedBox(height: 12),
                      Semantics(liveRegion: true, child: Text(_message!)),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(receiver == null
                    ? locals.remoteClose
                    : locals.remoteKeepReceiving),
              ),
            ],
          );
        },
      );
}
