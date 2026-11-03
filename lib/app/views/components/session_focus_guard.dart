import 'package:flutter/widgets.dart';

/// Keeps session controls inert during a switch, then restores TV remote focus.
class SessionFocusGuard extends StatefulWidget {
  final bool blocked;
  final bool restoreFocus;
  final Widget child;

  const SessionFocusGuard(
      {super.key,
      required this.blocked,
      required this.restoreFocus,
      required this.child});

  @override
  State<SessionFocusGuard> createState() => _SessionFocusGuardState();
}

class _SessionFocusGuardState extends State<SessionFocusGuard> {
  final _scope = FocusScopeNode(debugLabel: 'Session content');
  FocusNode? _previousFocus;

  @override
  void initState() {
    super.initState();
    _restoreAfterFrame();
  }

  @override
  void didUpdateWidget(SessionFocusGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.blocked && widget.blocked) {
      final focus = FocusManager.instance.primaryFocus;
      _previousFocus = focus != null &&
              focus is! FocusScopeNode &&
              focus.children.isEmpty &&
              focus.ancestors.contains(_scope)
          ? focus
          : null;
    }
    if (oldWidget.blocked && !widget.blocked) _restoreAfterFrame();
  }

  void _restoreAfterFrame() {
    if (widget.blocked || !widget.restoreFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.blocked || !widget.restoreFocus) return;
      // Let the active route's own autofocus win if it was able to run.
      FocusManager.instance.applyFocusChangesIfNeeded();
      final current = FocusManager.instance.primaryFocus;
      if (current != null &&
          current is! FocusScopeNode &&
          current.children.isEmpty &&
          current.canRequestFocus &&
          current.ancestors.contains(_scope)) {
        return;
      }
      final previous = _previousFocus;
      _previousFocus = null;
      if (previous != null &&
          previous.context?.mounted == true &&
          previous.canRequestFocus &&
          previous.ancestors.contains(_scope)) {
        previous.requestFocus();
        return;
      }

      // ExcludeFocus does not replay autofocus after unblocking. Traverse into
      // the active navigator/route scopes until an actionable control is found.
      final seed = _scope.traversalDescendants
          .where((node) => node is! FocusScopeNode && node.children.isEmpty)
          .firstOrNull;
      if (seed == null || seed.context?.mounted != true) return;
      final policy = FocusTraversalGroup.maybeOf(seed.context!) ??
          ReadingOrderTraversalPolicy();
      final candidate = policy.findFirstFocus(seed, ignoreCurrentFocus: true);
      final target =
          candidate == null || candidate is FocusScopeNode ? seed : candidate;
      target.requestFocus();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
      node: _scope,
      child: ExcludeFocus(
          excluding: widget.blocked,
          child: ExcludeSemantics(
              excluding: widget.blocked, child: widget.child)));
}
