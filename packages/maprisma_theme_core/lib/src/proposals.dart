import 'dart:async';
import 'dart:math';

import 'context.dart';
import 'rules.dart';

const askAiBlockedText = 'Switched off in Maprisma Settings › AI';
final _boundaryKey = Object();
final _outcomeKey = Object();
void reportAskAiOutcome(String result) =>
    (Zone.current[_outcomeKey] as void Function(String)?)?.call(result);

/// Called after preparation, immediately before publishing a change. Zones keep
/// concurrent manual requests separate from an Ask request (including setup jobs).
void checkAskAiBoundary() =>
    (Zone.current[_boundaryKey] as void Function()?)?.call();

final class AskProposal {
  AskProposal(
    this.actions,
    this.target,
    this.source,
    this.editable,
    this.picturePrompt,
  );
  final Set<String> actions;
  final String target;
  final String? source;
  final bool editable;
  final String? picturePrompt;
}

final class ProposalBook {
  final _random = Random.secure();
  final _items = <String, AskProposal>{};

  String issue(
    Set<String> actions,
    String target, {
    String? source,
    String? picturePrompt,
    bool editable = false,
  }) {
    final id = List.generate(
      24,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _items[id] = AskProposal(
      Set.unmodifiable(actions),
      target,
      source,
      editable,
      picturePrompt,
    );
    return id;
  }

  void clear() => _items.clear();

  Map<String, dynamic> candidate(Map<String, dynamic> c) {
    final actions = <String>{
      if (c['kind'] == 'installed') 'theme.apply',
      if (c['kind'] == 'catalog') ...['theme.install', 'theme.apply'],
      if (c['kind'] != 'installed' && c['kind'] != 'catalog') ...[
        'theme.edit',
        'theme.apply',
      ],
      if (c['picture_prompt'] is String) 'theme.generate',
      if (c['wallpaper_query'] is String ||
          c['wallpaper_images'] != null ||
          c['images'] != null ||
          c['picture_prompt'] is String) ...[
        'theme.wallpapers',
        'theme.apply',
      ],
    };
    return {
      ...c,
      'proposal': issue(
        actions,
        '${c['theme'] ?? ''}',
        picturePrompt: c['picture_prompt'] as String?,
        source: c['kind'] == 'catalog' ? 'omarchy' : null,
        editable: c['kind'] != 'installed' && c['kind'] != 'catalog',
      ),
    };
  }

  Set<String> actionsFor(
    Ctx ctx,
    String method,
    Map<String, dynamic> p,
  ) => switch (method) {
    'themes.apply' || 'wallpapers.set' => {
      'theme.apply',
      if (p['with_wallpaper'] == true) 'theme.wallpapers',
    },
    'custom.save' => {
      'theme.edit',
      if (p['with_wallpaper'] == true) ...['theme.wallpapers', 'theme.apply'],
      if (p['apply'] == true ||
          (p['edit'] != null && p['edit'] == ctx.current.slug))
        'theme.apply',
    },
    'import.omarchy_install' ||
    'import.cosmic_install' ||
    'import.kde_install' => {
      'theme.install',
      if (p['apply'] == true) 'theme.apply',
    },
    'wallhaven.add' ||
    'webimg.add' ||
    'create.add' => {'theme.wallpapers', if (p['set'] == true) 'theme.apply'},
    'create.make' || 'create.setup' => {'theme.generate'},
    _ => {},
  };

  Future<Map<String, dynamic>> execute(
    Ctx ctx,
    String method,
    Map<String, dynamic> p,
    Handler handler,
  ) async {
    final actions = actionsFor(ctx, method, p);
    if (p['proposal'] == null || actions.isEmpty) return handler(p);
    final id = '${p['proposal']}';
    final proposal = _items[id];
    final target =
        '${p['name'] ?? p['slug'] ?? p['id'] ?? proposal?.target ?? ''}';
    // with_wallpaper reserves the following step before any change; that step
    // writes its own outcome when it actually adds the wallpaper.
    final loggedActions = actionsFor(ctx, method, {
      ...p,
      'with_wallpaper': false,
    });
    void log(String result) {
      for (final action in loggedActions) {
        appendAskAiLog(
          ctx.paths,
          op: id,
          app: 'theme',
          action: action,
          target: target,
          result: result,
        );
      }
    }

    void check() {
      final requested = actionsFor(ctx, method, p);
      final boundTarget = '${p['name'] ?? p['slug'] ?? p['id'] ?? ''}';
      final source = switch (method) {
        'import.omarchy_install' => 'omarchy',
        'import.cosmic_install' => 'cosmic',
        'import.kde_install' => 'kde',
        _ => null,
      };
      if (proposal == null ||
          (method == 'create.make' && proposal.picturePrompt != p['prompt']) ||
          !proposal.actions.containsAll(requested) ||
          (!proposal.editable &&
              boundTarget.isNotEmpty &&
              proposal.target != boundTarget) ||
          (source != null && proposal.source != source) ||
          requested.any(
            (a) => !askAiAllowed(ctx.paths, a, source: proposal.source),
          )) {
        throw RouteError('ask_ai_blocked', askAiBlockedText);
      }
    }

    try {
      check();
      final result = await runZoned(
        () => handler(p),
        zoneValues: {_boundaryKey: check, _outcomeKey: log},
      );
      if (method == 'create.setup') return result;
      log(
        result['cancelled'] == true
            ? 'cancelled'
            : result['apply_error'] != null
            ? 'failed'
            : 'done',
      );
      return result;
    } catch (e) {
      log(
        e is RouteError && e.code == 'ask_ai_blocked'
            ? 'blocked'
            : e is RouteError && e.code == 'cancelled'
            ? 'cancelled'
            : 'failed',
      );
      rethrow;
    }
  }
}
