import 'i18n.dart';
import 'dart:convert';

import 'context.dart';
import 'desktop.dart';
import 'desktops.dart';
import 'paths.dart';
import 'protocol.dart';
import 'routes.dart';
import 'trash.dart';

const coreVersion = '0.1.0';

/// The core behind the protocol (docs/protocol.md): one JSON frame in, one out.
final class CoreService {
  CoreService({required Map<String, String> environment, Paths? paths, Desktop? desktop, DateTime Function()? clock}) {
    final p = paths ?? Paths.fromEnvironment(environment);
    ctx = Ctx(paths: p, desktop: desktop ?? selectDesktop(p, environment), environment: environment, clock: clock);
    routes = {
      'core.hello': (_) async => {'version': coreVersion, 'protocol': protocolVersion, 'desktop': ctx.desktop.id},
      /// The active desktop backend: {id, name, terminal, caps} (docs/multi-desktop.md).
      'desktop.info': (_) async => desktopInfo(ctx.desktop),
      ...allRoutes(ctx),
    };
    ctx.automationChanged(); // once, with every module's part (tiling from presets)
  }

  late final Ctx ctx;
  late final Map<String, Handler> routes;

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    languageSetting = ctx.settings.get('language') as String? ?? 'auto';
    languageEnvironment = ctx.environment;
    final handler = routes[method];
    if (handler == null) throw RouteError('unknown_route', method);
    try {
      return await handler(params);
    } on TrashUnavailable catch (e) {
      throw RouteError('no_trash', '$e');
    }
  }

  Future<String> handleAsync(String frame) async {
    int? id;
    try {
      final request = Request.decode(frame);
      id = request.id;
      final result = await call(request.method, request.params);
      final out = jsonEncode({'id': id, 'result': result});
      if (out.length > maxResponse) return jsonEncode({'id': id, 'error': {'code': 'response_too_large'}});
      return out;
    } on RouteError catch (e) {
      return jsonEncode({'id': id, 'error': {'code': e.code, 'message': e.message}});
    } on FormatException {
      return jsonEncode({'id': id, 'error': {'code': 'bad_request'}});
    } on ServiceError catch (e) {
      return jsonEncode({'id': id, 'error': {'code': e.code, 'message': e.reason}});
    } on ArgumentError catch (e) {
      return jsonEncode({'id': id, 'error': {'code': 'bad_params', 'message': '${e.name}'}});
    } catch (e) {
      return jsonEncode({'id': id, 'error': {'code': 'internal', 'message': '$e'}});
    }
  }

  void dispose() {}
}
