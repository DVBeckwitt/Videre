import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Uses the app's selection without restarting an asynchronous scan on rebuild.
/// Standalone consumers resolve their initial selection once per mount.
class SelectedServerBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, Server? server) builder;

  const SelectedServerBuilder({super.key, required this.builder});

  @override
  State<SelectedServerBuilder> createState() => _SelectedServerBuilderState();
}

class _SelectedServerBuilderState extends State<SelectedServerBuilder> {
  Future<Server>? _initialServer;

  Server _fresh(Server server) => db.getServer(server.url) ?? server;

  @override
  Widget build(BuildContext context) {
    final selected =
        context.select<AppCubit?, Server?>((app) => app?.state.server);
    if (selected != null) return widget.builder(context, _fresh(selected));
    return FutureBuilder<Server>(
        future: _initialServer ??= db.getCurrentlySelectedServer(),
        builder: (context, snapshot) => widget.builder(
            context, snapshot.data == null ? null : _fresh(snapshot.data!)));
  }
}
