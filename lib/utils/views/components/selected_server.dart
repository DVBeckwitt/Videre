import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Binds account-owned content without changing the app's selected account.
/// An explicit null owner blocks requests; absence of this scope uses selection.
class ServerScope extends InheritedWidget {
  final Server? server;

  const ServerScope({super.key, required this.server, required super.child});

  Server? resolve() {
    final owner = server;
    if (owner == null || owner.profileId != db.profileId) return null;
    final current = db.forProfile(owner.profileId).getAccount(owner.accountId);
    final expected = Uri.tryParse(owner.url);
    final actual = Uri.tryParse(current?.url ?? '');
    bool valid(Uri? uri) =>
        uri != null &&
        const {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty;
    return valid(expected) &&
            valid(actual) &&
            actual!.origin == expected!.origin
        ? current
        : null;
  }

  @override
  bool updateShouldNotify(ServerScope oldWidget) => server != oldWidget.server;
}

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

  Server? _fresh(Server server) =>
      db.forProfile(server.profileId).getAccount(server.accountId);

  @override
  Widget build(BuildContext context) {
    final selected =
        context.select<AppCubit?, Server?>((app) => app?.state.server);
    final scope = context.dependOnInheritedWidgetOfExactType<ServerScope>();
    if (scope != null) return widget.builder(context, scope.resolve());
    if (selected != null) return widget.builder(context, _fresh(selected));
    return FutureBuilder<Server>(
        future: _initialServer ??= db.getCurrentlySelectedServer(),
        builder: (context, snapshot) => widget.builder(
            context, snapshot.data == null ? null : _fresh(snapshot.data!)));
  }
}
