import 'dart:async';

import 'package:flutter/services.dart';

/// Something dropped onto the window: image bytes (a picture from a browser)
/// or a text/uri-list (files from the file manager).
final class Drop {
  Drop(this.type, this.data);
  final String type;
  final Uint8List data;
  bool get isUriList => type == 'text/uri-list';
}

/// The native window (linux/runner/my_application.cc, "maprisma-theme/window").
final class AppWindow {
  AppWindow._() {
    _channel.setMethodCallHandler(_handle);
  }
  static final instance = AppWindow._();
  static const _channel = MethodChannel('maprisma-theme/window');

  final shown = StreamController<void>.broadcast();
  final hidden = StreamController<void>.broadcast();
  final focus = StreamController<bool>.broadcast();

  /// The pointer position while something is dragged over the window, null when it left.
  final dragging = StreamController<Offset?>.broadcast();
  final drops = StreamController<Drop>.broadcast();

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'shown':
        shown.add(null);
      case 'hidden':
        hidden.add(null);
      case 'focus':
        focus.add(true);
      case 'blur':
        focus.add(false);
      case 'dragMotion':
        final a = call.arguments as List;
        dragging.add(Offset((a[0] as int).toDouble(), (a[1] as int).toDouble()));
      case 'dragLeave':
        dragging.add(null);
      case 'drop':
        final m = call.arguments as Map;
        drops.add(Drop(m['type'] as String, m['data'] as Uint8List));
    }
    return null;
  }

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      // tests
    } on PlatformException {
      // ignore
    }
  }

  Future<void> hide() => _call('hide');
  Future<void> present() => _call('present');
  Future<void> titlebar(bool dark) => _call('titlebar', dark);
  Future<void> resize(int width, int height) => _call('size', [width, height]);
  Future<void> maximize(bool on) => _call('maximize', on);
  Future<bool> maximized() async {
    try {
      return await _channel.invokeMethod<bool>('maximized') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
