import 'dart:async';

import 'package:flutter/services.dart';
import 'package:maprisma_ui/window.dart';

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
    _channel.setHandler(_handle);
  }
  static final instance = AppWindow._();
  final _channel = WindowChannel('maprisma-theme/window');

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

  Future<void> hide() => _channel.hide();
  Future<void> present() => _channel.present();

  /// Light or dark, and the header bar in the palette's [background], [foreground] and [border]
  /// (`#rrggbb`), also when the theme changes while the window is open.
  Future<void> titlebar(bool dark, {String? background, String? foreground, String? border}) =>
      _channel.titlebar(dark, background: background, foreground: foreground, border: border);
  Future<void> resize(int width, int height) => _channel.resize(width, height);
  Future<void> maximize(bool on) => _channel.maximize(on);

  /// {width, height, free}: GTK's size (title bar included) and whether it is the user's
  /// (shown, not maximized, fullscreen or tiled); null without the runner (tests).
  Future<Object?> geometry() => _channel.geometry();
  Future<bool> maximized() => _channel.maximized();
}
