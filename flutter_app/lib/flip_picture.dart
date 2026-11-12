import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'i18n.dart';
import 'theme.dart';
import 'widgets.dart';

const flipDuration = 0.42; // seconds for initial/close 180° flip
const flipStepDuration = 0.30; // seconds for < / > arrow step
const peekDelayMs = 70; // skim guard before subtle ~16° 3D edge-lift hint
const peekProgress = 0.19; // ~16° cosine-eased lift (180 * (0.5 - 0.5 * cos(pi * 0.19)))

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// A theme preview that lifts slightly and rotates 180° in 3D when selected or
/// hovered to reveal the theme's wallpapers, with `<` / `>` cycle buttons
/// (including the original preview `-1`) and a top-left pin button.
class FlipPicture extends StatefulWidget {
  const FlipPicture({
    super.key,
    required this.slug,
    required this.preview,
    required this.wallpapers,
    required this.colors,
    required this.borderRadius,
    required this.active,
    this.pageVisible = true,
    required this.themeCurrent,
    required this.pinApplyTheme,
    required this.delaySeconds,
    required this.badges,
    required this.menuButton,
    this.activeWallpaper,
    this.canPin = true,
    this.onPin,
  });

  final String slug;
  final String preview;
  final List<String> wallpapers;
  final Map colors;
  final double borderRadius;
  final bool active;
  final bool pageVisible;
  final bool themeCurrent;
  final bool pinApplyTheme;
  final double delaySeconds;
  final String? activeWallpaper;
  final bool canPin;
  final Widget badges;
  final Widget menuButton;
  final Future<bool> Function(String path)? onPin;

  @override
  State<FlipPicture> createState() => FlipPictureState();
}

class FlipPictureState extends State<FlipPicture> with SingleTickerProviderStateMixin {
  late List<String> _wallpapers;
  String? _activeName;
  String? _pinnedOverrideName;
  String? _promoteName;
  int _delayMs = 2000;

  bool _selected = false;
  bool _interactive = false; // true once rotation or manual arrow mode is active
  bool _navSteady = false; // true once < / > stay visible across preview + wallpapers
  int _fromFace = -1; // -1 = original preview, 0..N-1 = wallpaper index
  int _toFace = 0;
  double _direction = 1.0;
  double _target = 0.0;
  double _progress = 0.0;
  (int, double)? _queued;

  Timer? _peekTimer;
  Timer? _delayTimer;
  late final Ticker _ticker;
  Duration? _lastElapsed;
  final Set<String> _prefetched = {};

  int get visibleFace {
    final eased = 0.5 - 0.5 * math.cos(math.pi * _progress);
    return eased <= 0.5 ? _fromFace : _toFace;
  }

  bool get isShowingWallpaper => visibleFace >= 0;

  String? get currentWallpaperPath {
    final face = visibleFace;
    return face >= 0 && face < _wallpapers.length ? _wallpapers[face] : null;
  }

  bool get isCurrentWallpaperPinned {
    final path = currentWallpaperPath;
    return path != null && _activeName != null && _baseName(path) == _activeName;
  }

  double get currentAngleDegrees => _faceAndAngle().$2;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _wallpapers = List<String>.of(widget.wallpapers);
    _delayMs = math.max(0, (widget.delaySeconds * 1000).round());
    _syncActiveName();
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) setSelected(true);
      });
    }
  }

  @override
  void didUpdateWidget(FlipPicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slug != widget.slug) {
      _cancelTimers();
      _stopTicker();
      _wallpapers = List<String>.of(widget.wallpapers);
      _pinnedOverrideName = null;
      _promoteName = null;
      _selected = false;
      _interactive = false;
      _navSteady = false;
      _fromFace = -1;
      _toFace = 0;
      _direction = 1.0;
      _target = 0.0;
      _progress = 0.0;
      _queued = null;
      _prefetched.clear();
    } else if (!_sameList(oldWidget.wallpapers, widget.wallpapers)) {
      if (_fromFace == -1 && _progress <= 0.0) {
        _wallpapers = List<String>.of(widget.wallpapers);
        _promoteName = null;
      } else if (_sameSet(_wallpapers, widget.wallpapers)) {
        // Same wallpapers re-ordered after pinning: keep indices steady while open
        // and promote to front once the card closes back to preview.
        if (widget.wallpapers.isNotEmpty) {
          _promoteName = _baseName(widget.wallpapers.first);
        }
      } else {
        _wallpapers = List<String>.of(widget.wallpapers);
        if (_wallpapers.isEmpty) {
          resetFlip();
        } else {
          if (_fromFace >= _wallpapers.length) _fromFace = _wallpapers.length - 1;
          if (_toFace >= _wallpapers.length) _toFace = 0;
        }
      }
    }

    final newDelayMs = math.max(0, (widget.delaySeconds * 1000).round());
    final delayChanged = newDelayMs != _delayMs;
    _delayMs = newDelayMs;

    if (oldWidget.themeCurrent != widget.themeCurrent || oldWidget.pinApplyTheme != widget.pinApplyTheme) {
      _pinnedOverrideName = null;
    } else if (_pinnedOverrideName != null &&
        widget.activeWallpaper != null &&
        _baseName(widget.activeWallpaper!) == _pinnedOverrideName) {
      _pinnedOverrideName = null;
    }
    _syncActiveName();

    if (!widget.pageVisible) {
      if (_selected || _fromFace != -1 || _progress > 0.0 || _interactive) {
        resetFlip();
      }
      if (!_sameList(_wallpapers, widget.wallpapers)) {
        _wallpapers = List<String>.of(widget.wallpapers);
        _promoteName = null;
      }
      _syncActiveName();
      return;
    }

    if (widget.active != _selected) {
      setSelected(widget.active);
    } else if (delayChanged && _selected) {
      if (_delayMs <= 0 && _fromFace == -1) {
        _cancelTimers();
        _queued = null;
        _interactive = true;
        _navSteady = true;
        if (_progress > 0.0) _animateTo(0.0);
      }
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    _ticker.dispose();
    super.dispose();
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameSet(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  void _syncActiveName() {
    final trackPinned = widget.themeCurrent || !widget.pinApplyTheme;
    if (!trackPinned) {
      _activeName = null;
      return;
    }
    if (_pinnedOverrideName != null) {
      _activeName = _pinnedOverrideName;
      return;
    }
    if (widget.themeCurrent) {
      final bg = widget.activeWallpaper;
      _activeName = bg != null && bg.isNotEmpty ? _baseName(bg) : null;
    } else {
      // Only the wallpaper the page says is remembered for it (never a first one never chosen).
      final bg = widget.activeWallpaper;
      _activeName = bg != null && bg.isNotEmpty ? _baseName(bg) : null;
    }
  }

  void _promote(String name) {
    final idx = _wallpapers.indexWhere((p) => _baseName(p) == name);
    if (idx > 0) {
      _wallpapers = [..._wallpapers.sublist(idx), ..._wallpapers.sublist(0, idx)];
    }
  }

  void _cancelTimers() {
    _peekTimer?.cancel();
    _peekTimer = null;
    _delayTimer?.cancel();
    _delayTimer = null;
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
    _lastElapsed = null;
  }

  void _prefetchPath(String path) {
    if (!mounted || _prefetched.contains(path)) return;
    _prefetched.add(path);
    precacheImage(ResizeImage(FileImage(File(path)), width: 640), context).catchError((Object _) {});
  }

  void _prefetchAround(int index) {
    final n = _wallpapers.length;
    if (n == 0) return;
    _prefetchPath(widget.preview);
    if (index < 0) {
      _prefetchPath(_wallpapers[0]);
      if (n > 1) _prefetchPath(_wallpapers[n - 1]);
      return;
    }
    _prefetchPath(_wallpapers[index % n]);
    if (n > 1) {
      _prefetchPath(_wallpapers[(index + 1) % n]);
      _prefetchPath(_wallpapers[(index - 1) % n]);
    }
  }

  void setSelected(bool selected) {
    if (selected == _selected) {
      if (selected) _activate();
      return;
    }
    _selected = selected;
    if (selected) {
      _activate();
    } else {
      _closeToPreview();
    }
    if (mounted) setState(() {});
  }

  void _activate() {
    if (_wallpapers.isEmpty) return;
    _prefetchAround(0);
    if (_delayMs <= 0) {
      _cancelTimers();
      _interactive = true;
      _navSteady = true;
      if (mounted) setState(() {});
      return;
    }
    if (_interactive || _peekTimer != null || _delayTimer != null) return;
    final peekMs = math.min(peekDelayMs, _delayMs);
    final remMs = math.max(40, _delayMs - peekMs);
    if (_fromFace == -1 && _progress <= 0.0) {
      _peekTimer = Timer(Duration(milliseconds: peekMs), _onHoverPeek);
    } else if (_fromFace == -1 && _toFace >= 0) {
      _queued = null;
      if (_progress <= peekProgress + 0.02) {
        _animateTo(peekProgress);
        _delayTimer ??= Timer(Duration(milliseconds: remMs), _onDelayDone);
      } else {
        _interactive = true;
        _animateTo(1.0);
      }
    } else if (_toFace == -1) {
      _interactive = true;
      if (_progress < 0.5) {
        _queued = null;
        _animateTo(0.0);
      } else {
        _queued = (0, 1.0);
        _animateTo(1.0);
      }
    }
  }

  void _onHoverPeek() {
    _peekTimer = null;
    if (!mounted || !_selected || _wallpapers.isEmpty) return;
    _fromFace = -1;
    _toFace = 0;
    _direction = 1.0;
    _animateTo(peekProgress);
    if (_delayTimer == null) {
      final peekMs = math.min(peekDelayMs, _delayMs);
      final remMs = math.max(40, _delayMs - peekMs);
      _delayTimer = Timer(Duration(milliseconds: remMs), _onDelayDone);
    }
  }

  void _onDelayDone() {
    _delayTimer = null;
    if (!mounted || !_selected || _wallpapers.isEmpty) return;
    _interactive = true;
    _fromFace = -1;
    _toFace = 0;
    _direction = 1.0;
    _animateTo(1.0);
  }

  void _closeToPreview() {
    _interactive = false;
    _navSteady = false;
    _cancelTimers();
    _queued = null;
    if (_fromFace == -1 && _progress <= 0.0) {
      _target = 0.0;
      if (_promoteName != null) {
        _promote(_promoteName!);
        _promoteName = null;
      }
      if (mounted) setState(() {});
      return;
    }
    if (_fromFace == -1) {
      _animateTo(0.0);
    } else if (_toFace == -1) {
      _animateTo(1.0);
    } else if (_progress >= 1.0) {
      _fromFace = _toFace;
      _toFace = -1;
      _direction = -1.0;
      _progress = 0.0;
      _animateTo(1.0);
    } else if (_progress <= 0.0) {
      _toFace = -1;
      _direction = -1.0;
      _progress = 0.0;
      _animateTo(1.0);
    } else if (_progress < 0.5 && _target == 1.0) {
      _queued = (-1, -1.0);
      _animateTo(0.0);
    } else {
      _queued = (-1, -1.0);
      _animateTo(_target);
    }
  }

  void resetFlip() {
    _selected = false;
    _interactive = false;
    _navSteady = false;
    _queued = null;
    _cancelTimers();
    _stopTicker();
    _fromFace = -1;
    _toFace = 0;
    _direction = 1.0;
    _target = 0.0;
    _progress = 0.0;
    if (_promoteName != null) {
      _promote(_promoteName!);
      _promoteName = null;
    }
    if (mounted) setState(() {});
  }

  int _nextFaceInCycle(int face, int delta) {
    final n = _wallpapers.length;
    return ((face + 1 + delta) % (n + 1)) - 1;
  }

  void rotateStep(int stepDir) {
    if (_wallpapers.isEmpty || !_interactive) return;
    if (!_navSteady && !isShowingWallpaper) return;
    _navSteady = true;
    final sign = stepDir >= 0 ? 1.0 : -1.0;
    final delta = stepDir >= 0 ? 1 : -1;
    if (_progress >= 1.0) {
      final cur = _toFace;
      final nxt = _nextFaceInCycle(cur, delta);
      _prefetchAround(nxt);
      _fromFace = cur;
      _toFace = nxt;
      _direction = sign;
      _progress = 0.0;
      _animateTo(1.0);
      return;
    }
    if (_progress <= 0.0) {
      final cur = _fromFace;
      final nxt = _nextFaceInCycle(cur, delta);
      _prefetchAround(nxt);
      _fromFace = cur;
      _toFace = nxt;
      _direction = sign;
      _progress = 0.0;
      _animateTo(1.0);
      return;
    }
    if (_progress < 0.5) {
      if (_target == 1.0 && (sign > 0) != (_direction > 0)) {
        _queued = null;
        _animateTo(0.0);
        return;
      }
      if (_target == 0.0 && (sign > 0) == (_direction > 0)) {
        _queued = null;
        _animateTo(1.0);
        return;
      }
    }
    final endFace = _target == 1.0 ? _toFace : _fromFace;
    final nxt = _nextFaceInCycle(endFace, delta);
    _prefetchAround(nxt);
    _queued = (nxt, sign);
    _animateTo(_target);
  }

  void _animateTo(double target) {
    _target = target;
    if (!_ticker.isActive) {
      _lastElapsed = null;
      _ticker.start();
    }
    if (mounted) setState(() {});
  }

  void _onTick(Duration elapsed) {
    final double dt;
    if (_lastElapsed == null) {
      _lastElapsed = elapsed;
      dt = 1.0 / 60.0;
    } else {
      final us = (elapsed - _lastElapsed!).inMicroseconds;
      _lastElapsed = elapsed;
      dt = us <= 0 ? 1.0 / 60.0 : math.min(0.1, us / 1000000.0);
    }
    final keepGoing = _step(dt);
    if (!keepGoing) _stopTicker();
    if (mounted) setState(() {});
  }

  bool _step(double dt) {
    var dur = _navSteady ? flipStepDuration : flipDuration;
    if (_queued != null) dur *= 0.6;
    var stepScale = 1.0;
    if (_fromFace == -1 && _target == peekProgress) {
      final rem = math.max(0.0, peekProgress - _progress);
      stepScale = math.max(0.32, math.min(1.0, rem / 0.09)) * 1.15;
    } else if (_fromFace == -1 && _target == 0.0 && _progress <= peekProgress + 0.01) {
      stepScale = math.max(0.32, math.min(1.0, _progress / 0.09)) * 1.05;
    }

    if (_target > _progress) {
      _progress = math.min(_target, _progress + (dt / dur) * stepScale);
    } else if (_target < _progress) {
      _progress = math.max(_target, _progress - (dt / dur) * stepScale);
    }

    if (_progress == _target) {
      if (_queued != null) {
        final (nxtFace, nxtDir) = _queued!;
        _queued = null;
        final curFace = _target == 1.0 ? _toFace : _fromFace;
        if (nxtFace != curFace) {
          _prefetchAround(nxtFace);
          _fromFace = curFace;
          _toFace = nxtFace;
          _direction = nxtDir;
          _progress = 0.0;
          _target = 1.0;
          return true;
        }
      }
      if (_target == 1.0 && _toFace == -1) {
        _fromFace = -1;
        _toFace = 0;
        _direction = 1.0;
        _progress = 0.0;
        _target = 0.0;
        if (!_selected && _promoteName != null) {
          _promote(_promoteName!);
          _promoteName = null;
        }
      } else if (_target == 0.0 && _fromFace == -1) {
        if (!_selected && _promoteName != null) {
          _promote(_promoteName!);
          _promoteName = null;
        }
      }
      if (_interactive && ((_target == 1.0 && _progress >= 1.0) || (_target == 0.0 && _progress <= 0.0))) {
        _navSteady = true;
      }
    }

    return _progress != _target || _queued != null;
  }

  (int, double) _faceAndAngle() {
    final eased = 0.5 - 0.5 * math.cos(math.pi * _progress);
    if (eased <= 0.5) {
      return (_fromFace, _direction * (180.0 * eased));
    }
    return (_toFace, _direction * (180.0 * (eased - 1.0)));
  }

  /// Every click is handed on: the page runs one pin at a time and the latest waiting one after
  /// it (a superseded click answers false and changes nothing here).
  Future<void> _handlePin() async {
    if (widget.onPin == null) return;
    final path = currentWallpaperPath;
    if (path == null || isCurrentWallpaperPinned) return;
    final ok = await widget.onPin!(path);
    if (!ok || !mounted) return;
    if (widget.themeCurrent || !widget.pinApplyTheme) {
      final name = _baseName(path);
      setState(() {
        _pinnedOverrideName = name;
        _activeName = name;
        if (_fromFace == -1 && _progress <= 0.0) {
          _promote(name);
        } else {
          _promoteName = name;
        }
      });
    }
  }

  String _pinTooltip(int face, bool pinned) {
    final total = _wallpapers.length;
    final suffix = total > 1 ? ' (${face + 1}/$total)' : '';
    final String base;
    if (widget.themeCurrent) {
      base = pinned ? tr("Current background") : tr("Set as background");
    } else if (widget.pinApplyTheme) {
      base = tr("Apply theme with this wallpaper");
    } else {
      base = pinned ? tr("Current wallpaper for this theme") : tr("Set as wallpaper for this theme");
    }
    return '$base$suffix';
  }

  Widget _faceImage(int face) {
    final path = face >= 0 && face < _wallpapers.length ? _wallpapers[face] : widget.preview;
    return Image(
      key: ValueKey('face-$path'),
      image: ResizeImage(FileImage(File(path)), width: 640),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => ColorPreview(colors: widget.colors),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (face, localDeg) = _faceAndAngle();
    final isIdleFront = _fromFace == -1 && _progress <= 0.0;
    final double badgesOpacity;
    if (face == -1) {
      final fade = math.max(0.0, (localDeg.abs() - 20.0) / 28.0);
      badgesOpacity = math.max(0.0, 1.0 - fade);
    } else {
      badgesOpacity = 0.0;
    }
    final faceOpacity = (1.0 - localDeg.abs() / 55.0).clamp(0.0, 1.0);
    final showNav = _wallpapers.isNotEmpty && ((_interactive && _navSteady) || face >= 0);
    final navOpacity = (_interactive && _navSteady) ? 1.0 : faceOpacity;
    final showPin = widget.canPin && face >= 0 && face < _wallpapers.length;
    final pinned = showPin && _activeName != null && _baseName(_wallpapers[face]) == _activeName;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        Widget cardFace;
        if (isIdleFront || w <= 0 || h <= 0) {
          cardFace = ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: SizedBox.expand(child: _faceImage(-1)),
          );
        } else {
          final d = math.max(w * 1.8, 260.0);
          final rad = localDeg * math.pi / 180.0;
          final scale = (d - (w / 2.0) * math.sin(rad).abs()) / d;
          final shade = 0.38 * math.sin(rad).abs();
          final rimAlpha = 0.42 * math.sin(math.min(math.pi * 0.5, rad.abs() * 2.4));
          final transform = Matrix4.identity()
            ..setEntry(3, 2, -1.0 / d)
            ..rotateY(rad)
            ..multiply(Matrix4.diagonal3Values(scale, scale, 1.0));
          cardFace = Transform(
            alignment: Alignment.center,
            transform: transform,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _faceImage(face),
                  if (shade > 0.005)
                    IgnorePointer(
                      child: ColoredBox(color: Colors.black.withValues(alpha: shade)),
                    ),
                  if (rimAlpha > 0.02 && localDeg.abs() < 84.0)
                    IgnorePointer(
                      child: Align(
                        alignment: localDeg > 0 ? Alignment.centerLeft : Alignment.centerRight,
                        child: Container(
                          width: math.min(2.0, w),
                          height: h,
                          color: Colors.white.withValues(alpha: rimAlpha),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            cardFace,
            Positioned(
              left: 6,
              right: 40,
              bottom: 6,
              child: IgnorePointer(
                ignoring: badgesOpacity <= 0.01,
                child: Opacity(opacity: badgesOpacity, child: widget.badges),
              ),
            ),
            if (showPin && faceOpacity > 0.01)
              Align(
                alignment: Alignment.topLeft,
                child: Opacity(
                  opacity: faceOpacity,
                  child: _FlipOverlayButton(
                    key: ValueKey('flip-pin-${widget.slug}'),
                    icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    tooltip: _pinTooltip(face, pinned),
                    pinned: pinned,
                    onTap: _handlePin,
                  ),
                ),
              ),
            if (showNav && navOpacity > 0.01) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Opacity(
                  opacity: navOpacity,
                  child: _FlipOverlayButton(
                    key: ValueKey('flip-prev-${widget.slug}'),
                    icon: Icons.chevron_left,
                    tooltip: _nextFaceInCycle(face, -1) == -1 ? tr("Preview") : tr("Previous wallpaper"),
                    onTap: () => rotateStep(-1),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: navOpacity,
                  child: _FlipOverlayButton(
                    key: ValueKey('flip-next-${widget.slug}'),
                    icon: Icons.chevron_right,
                    tooltip: _nextFaceInCycle(face, 1) == -1 ? tr("Preview") : tr("Next wallpaper"),
                    onTap: () => rotateStep(1),
                  ),
                ),
              ),
            ],
            Positioned(top: 0, right: 0, child: widget.menuButton),
          ],
        );
      },
    );
  }
}

class _FlipOverlayButton extends StatefulWidget {
  const _FlipOverlayButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.pinned = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool pinned;

  @override
  State<_FlipOverlayButton> createState() => _FlipOverlayButtonState();
}

class _FlipOverlayButtonState extends State<_FlipOverlayButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final marks = markColors(context);
    final r = cornerSizes(context).control;
    final Color bg;
    final Color fg;
    if (widget.pinned) {
      bg = marks.running;
      fg = look.bg;
    } else if (_hover) {
      bg = look.accent;
      fg = look.bg;
    } else {
      bg = Colors.black.withValues(alpha: .6);
      fg = Colors.white;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tooltip,
          child: Container(
            margin: const EdgeInsets.all(5),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(r)),
            child: Icon(widget.icon, size: 16, color: fg),
          ),
        ),
      ),
    );
  }
}
