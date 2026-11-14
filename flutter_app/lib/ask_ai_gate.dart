import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'i18n.dart';

/// Rules are read from the core when an Ask action is rendered, and refreshed
/// while the result stays visible. Manual controls do not use this widget.
class AskAiGate extends StatefulWidget {
  const AskAiGate({
    super.key,
    required this.actions,
    required this.builder,
    this.proposal,
  });
  final String? proposal;
  final List<String> actions;
  final Widget Function(bool allowed) builder;
  @override
  State<AskAiGate> createState() => _AskAiGateState();
}

class _AskAiGateState extends State<AskAiGate> {
  bool allowed = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    refresh();
  }

  @override
  void didUpdateWidget(AskAiGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    refresh();
  }

  Future<void> refresh() async {
    if (widget.proposal == null) {
      if (!allowed && mounted) setState(() => allowed = true);
      return;
    }
    try {
      final r = await AppScope.read(context).call('ask.rules');
      final actions = r['actions'] as Map? ?? const {};
      final next =
          r['level'] != 'answers' &&
          widget.actions.every((id) => actions[id] != false);
      if (mounted && next != allowed) setState(() => allowed = next);
    } catch (_) {
      if (mounted && allowed) setState(() => allowed = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 240),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (allowed)
          widget.builder(true)
        else
          FilledButton(
            onPressed: null,
            child: Text(tr('Switched off in Maprisma Settings › AI')),
          ),
        if (!allowed)
          TextButton(
            onPressed: () => AppScope.read(context).run('ask.open_settings'),
            child: Text(tr('Maprisma Settings › AI')),
          ),
      ],
    ),
  );
}
