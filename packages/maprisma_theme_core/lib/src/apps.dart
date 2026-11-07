import 'context.dart';
import 'themes.dart';

/// The terminal and editor colors from Omarchy's templates (docs/plan.md,
/// "App colors"). Returns the app ids that were updated.
///
/// TODO(apps module): render `templates/<app>.tpl` with [resolved], write the
/// include files, add the marked include lines, honour settings `apps`.
Future<List<String>> applyAppTemplates(Ctx ctx, ThemeInfo theme, Map<String, String> resolved) async => const [];
