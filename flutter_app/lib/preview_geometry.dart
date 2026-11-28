import 'dart:math' as math;
import 'dart:ui' show Rect;

/// All Workspace Presets layout identifiers in UI order.
const List<String> presetNames = [
  'side-by-side',
  'stacked',
  'master-left',
  'master-right',
  'columns',
  'grid',
  'floating',
  'scrolling',
  'none',
];

/// Presets that let windows move freely without a tiling window limit.
const List<String> freePresets = ['floating', 'scrolling'];

/// Presets that support a draggable split ratio divider.
const List<String> splitPresets = [
  'master-left',
  'master-right',
  'side-by-side',
  'stacked',
  'columns',
];

/// Compatible tiling presets for each window limit (`1..4`).
const Map<int, List<String>> tilingByCap = {
  1: ['side-by-side'],
  2: ['side-by-side', 'stacked'],
  3: ['columns', 'master-left', 'master-right'],
  4: ['columns', 'master-left', 'master-right', 'grid'],
};

/// Minimum allowed split ratio for any split-capable preset.
const double splitMin = 0.2;

/// Maximum allowed split ratio for two-region presets.
const double splitMax = 0.8;

/// Maximum allowed middle-column share for 3-window `columns`.
const double columnsSplitMax = 0.6;

/// Normalized outer and inter-window gap (`GAP` in `PreviewLogic.js`).
const double previewGap = 0.035;

/// Snap tolerance around the even split (`0.50`, or `1/3 -> 0.33` for `columns`).
const double splitSnapThreshold = 0.025;

/// Built-in default tiling preset for a window limit [cap].
String builtinDefaultPreset(int cap) => switch (cap) {
  2 => 'side-by-side',
  3 => 'master-left',
  4 => 'grid',
  _ => 'side-by-side',
};

/// Whether a preset tile is active (not dimmed) for the given window limit [cap].
///
/// `none`, `floating`, `scrolling`, and COSMIC/KDE `default` are always
/// compatible; COSMIC/KDE `tiled` is compatible for any positive limit;
/// tiling presets check [tilingByCap].
bool isPresetCompatibleWithCap(String preset, int cap) {
  if (preset == 'none' || preset == 'default' || freePresets.contains(preset)) {
    return true;
  }
  if (preset == 'tiled') return cap >= 1;
  final allowed = tilingByCap[cap];
  return allowed != null && allowed.contains(preset);
}

/// Whether [preset] with window limit [cap] exposes a draggable split divider.
bool hasDivider(String preset, int cap) {
  if (preset == 'columns') return cap == 3;
  return splitPresets.contains(preset) && cap >= 2;
}

/// Allowed `(min, max)` split ratio range for [preset].
(double, double) splitRange(String preset) =>
    preset == 'columns' ? (splitMin, columnsSplitMax) : (splitMin, splitMax);

/// Clamps [value] into [splitRange] for [preset] and rounds to 2 decimals.
double clampSplit(String preset, double value) {
  final (minVal, maxVal) = splitRange(preset);
  if (value.isNaN) return preset == 'columns' ? 0.33 : 0.5;
  final clamped = value < minVal
      ? minVal
      : (value > maxVal ? maxVal : value);
  return (clamped * 100).round() / 100;
}

/// Clamps [value] to [splitRange] and snaps near the even split
/// (`0.50`, or `1/3 -> 0.33` for 3-window `columns`) within [splitSnapThreshold].
double snapSplit(String preset, double value) {
  final (minVal, maxVal) = splitRange(preset);
  if (value.isNaN) return preset == 'columns' ? 0.33 : 0.5;
  final clamped = value < minVal
      ? minVal
      : (value > maxVal ? maxVal : value);
  if (preset == 'columns') {
    return (clamped - 1 / 3).abs() < splitSnapThreshold
        ? 0.33
        : (clamped * 100).round() / 100;
  }
  return (clamped - 0.5).abs() < splitSnapThreshold
      ? 0.5
      : (clamped * 100).round() / 100;
}

/// Normalized `0..1` geometry of a draggable split divider inside the preview.
class DividerInfo {
  const DividerInfo({
    required this.vertical,
    required this.pos,
    required this.start,
    required this.end,
    required this.fromRight,
    required this.value,
    this.secondaryPos,
  });

  /// `true` for a vertical divider (dragged horizontally), `false` for horizontal.
  final bool vertical;

  /// Normalized `0..1` position perpendicular to the divider (`x` if [vertical],
  /// `y` otherwise).
  final double pos;

  /// Normalized `0..1` start coordinate along the divider's span.
  final double start;

  /// Normalized `0..1` end coordinate along the divider's span.
  final double end;

  /// `true` when the split ratio is measured from the right (`master-right`).
  final bool fromRight;

  /// Effective split ratio represented by this divider.
  final double value;

  /// Symmetric second vertical divider (`1 - pos`) for 3-window `columns`, or `null`.
  final double? secondaryPos;

  /// All normalized divider positions (`[pos]` or `[pos, secondaryPos]`).
  List<double> get positions =>
      secondaryPos == null ? [pos] : [pos, secondaryPos!];

  /// Whether normalized pointer coordinates `(u, v)` hit this divider within
  /// [tolerance] perpendicular to the line and inside `[start, end]` along it.
  bool hitTest(double u, double v, {double tolerance = previewGap * 0.7}) {
    final coord = vertical ? u : v;
    final along = vertical ? v : u;
    if (along < start || along > end) return false;
    if ((coord - pos).abs() <= tolerance) return true;
    final second = secondaryPos;
    return second != null && (coord - second).abs() <= tolerance;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DividerInfo &&
          vertical == other.vertical &&
          pos == other.pos &&
          start == other.start &&
          end == other.end &&
          fromRight == other.fromRight &&
          value == other.value &&
          secondaryPos == other.secondaryPos;

  @override
  int get hashCode =>
      Object.hash(vertical, pos, start, end, fromRight, value, secondaryPos);

  @override
  String toString() =>
      'DividerInfo(vertical: $vertical, pos: $pos, start: $start, end: $end, '
      'fromRight: $fromRight, value: $value, secondaryPos: $secondaryPos)';
}

/// Returns the draggable split divider for [preset] and window limit [count]
/// in normalized `0..1` coordinates, or `null` when [hasDivider] is `false`.
DividerInfo? presetDivider(String preset, int count, {double? split}) {
  if (!hasDivider(preset, count)) return null;
  const g = previewGap;
  if (preset == 'columns') {
    final (minVal, maxVal) = splitRange(preset);
    final raw = split ?? (1 / 3);
    final v = raw.isNaN ? (1 / 3) : raw.clamp(minVal, maxVal);
    final part = 1 - 4 * g;
    final side = (part - part * v) / 2;
    final pos = g + side + g / 2;
    return DividerInfo(
      vertical: true,
      pos: pos,
      start: g,
      end: 1 - g,
      fromRight: false,
      value: v,
      secondaryPos: 1 - pos,
    );
  }
  final raw = split ?? 0.5;
  final s = raw.isNaN ? 0.5 : raw.clamp(splitMin, splitMax);
  const part = 1 - 3 * g;
  if (preset == 'stacked') {
    return DividerInfo(
      vertical: false,
      pos: g + part * s + g / 2,
      start: g,
      end: 1 - g,
      fromRight: false,
      value: s,
    );
  }
  final fromRight = preset == 'master-right';
  final share = fromRight ? 1 - s : s;
  return DividerInfo(
    vertical: true,
    pos: g + part * share + g / 2,
    start: g,
    end: 1 - g,
    fromRight: fromRight,
    value: s,
  );
}

/// Converts normalized `0..1` pointer coordinates `(u, v)` back to a clamped
/// and snapped split ratio for [preset].
double splitFromPointer(String preset, double u, double v) {
  const g = previewGap;
  if (preset == 'columns') {
    final raw = (2 * (u - 0.5).abs() - g) / (1 - 4 * g);
    return snapSplit(preset, raw);
  }
  final coord = preset == 'stacked' ? v : u;
  final share = (coord - 1.5 * g) / (1 - 3 * g);
  final raw = preset == 'master-right' ? 1 - share : share;
  return snapSplit(preset, raw);
}

/// The layout a `+` dropped at normalized `(u, v)` of the preview area asks for
/// at the new window limit [cap], or `null` when `cap <= 1`.
String? addZonePreset(int cap, double u, double v) {
  final cu = u.clamp(0.0, 1.0);
  final cv = v.clamp(0.0, 1.0);
  if (cap <= 1) return null;
  if (cap == 2) {
    return math.min(cv, 1 - cv) < math.min(cu, 1 - cu)
        ? 'stacked'
        : 'side-by-side';
  }
  final side = cu < 0.3 || cu > 0.7;
  if (cap >= 4 && side && (cv < 0.3 || cv > 0.7)) return 'grid';
  if (cu < 0.3) return 'master-left';
  if (cu > 0.7) return 'master-right';
  return 'columns';
}

/// Normalized `0..1` window rectangles for [preset] with [count] windows.
///
/// Supports all 9 Workspace Presets (`side-by-side`, `stacked`, `master-left`,
/// `master-right`, `columns`, `grid`, `floating`, `scrolling`, `none`) matching
/// `PreviewLogic.js`, plus COSMIC/KDE autotile modes (`tiled`, `default`).
List<Rect> presetRects(
  String preset,
  int count, {
  double? split,
  double aspect = 16 / 9,
}) {
  if (preset == 'tiled' || preset == 'default') {
    return _autotileRects(count, aspect: aspect);
  }

  const g = previewGap;
  const half = (1 - 3 * g) / 2;

  if (preset == 'floating') {
    if (count <= 0) return const [];
    return const [
      Rect.fromLTWH(0.08, 0.12, 0.5, 0.5),
      Rect.fromLTWH(0.3, 0.28, 0.5, 0.5),
      Rect.fromLTWH(0.5, 0.08, 0.42, 0.42),
    ];
  }
  if (preset == 'scrolling') {
    if (count <= 0) return const [];
    return const [
      Rect.fromLTWH(g, g, 0.42, 1 - 2 * g),
      Rect.fromLTWH(2 * g + 0.42, g, 0.42, 1 - 2 * g),
      Rect.fromLTWH(3 * g + 0.84, g, 0.42, 1 - 2 * g),
    ];
  }
  if (preset == 'none') {
    if (count <= 0) return const [];
    return const [
      Rect.fromLTWH(g, g, half, 1 - 2 * g),
      Rect.fromLTWH(2 * g + half, g, half, half),
      Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
    ];
  }

  if (count <= 0) return const [];
  if (count == 1) {
    return const [Rect.fromLTWH(g, g, 1 - 2 * g, 1 - 2 * g)];
  }

  final share = split == null || split.isNaN
      ? 0.5
      : split.clamp(splitMin, splitMax);
  final first = (1 - 3 * g) * share;
  final second = (1 - 3 * g) - first;

  List<Rect> column(double x, double w, int n) {
    final h = (1 - (n + 1) * g) / n;
    return [for (var i = 0; i < n; i++) Rect.fromLTWH(x, g + i * (h + g), w, h)];
  }

  switch (preset) {
    case 'side-by-side':
      return [
        Rect.fromLTWH(g, g, first, 1 - 2 * g),
        Rect.fromLTWH(2 * g + first, g, second, 1 - 2 * g),
      ];
    case 'stacked':
      return [
        Rect.fromLTWH(g, g, 1 - 2 * g, first),
        Rect.fromLTWH(g, 2 * g + first, 1 - 2 * g, second),
      ];
    case 'master-left':
      return [
        Rect.fromLTWH(g, g, first, 1 - 2 * g),
        ...column(2 * g + first, second, math.max(1, count - 1)),
      ];
    case 'master-right':
      return [
        ...column(g, second, math.max(1, count - 1)),
        Rect.fromLTWH(2 * g + second, g, first, 1 - 2 * g),
      ];
    case 'columns':
      final n = math.max(2, count);
      if (n == 3 && split != null && !split.isNaN) {
        const part = 1 - 4 * g;
        final mid = part * split.clamp(splitMin, columnsSplitMax);
        final side = (part - mid) / 2;
        return [
          Rect.fromLTWH(g, g, side, 1 - 2 * g),
          Rect.fromLTWH(2 * g + side, g, mid, 1 - 2 * g),
          Rect.fromLTWH(3 * g + side + mid, g, side, 1 - 2 * g),
        ];
      }
      final w = (1 - (n + 1) * g) / n;
      return [
        for (var i = 0; i < n; i++) Rect.fromLTWH(g + i * (w + g), g, w, 1 - 2 * g),
      ];
    case 'grid':
      return const [
        Rect.fromLTWH(g, g, half, half),
        Rect.fromLTWH(2 * g + half, g, half, half),
        Rect.fromLTWH(g, 2 * g + half, half, half),
        Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
      ];
    default:
      // Fallback matches PreviewLogic.js Native layout.
      return const [
        Rect.fromLTWH(g, g, half, 1 - 2 * g),
        Rect.fromLTWH(2 * g + half, g, half, half),
        Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
      ];
  }
}

/// COSMIC/KDE autotile: each new window splits the newest cell along its
/// longer side given [aspect], then applies [previewGap].
List<Rect> _autotileRects(int count, {double aspect = 16 / 9}) {
  final n = count.clamp(0, 8);
  if (n == 0) return const [];
  final cells = <Rect>[const Rect.fromLTWH(0, 0, 1, 1)];
  for (var i = 1; i < n; i++) {
    final last = cells.removeLast();
    if (last.width * aspect >= last.height) {
      cells.addAll([
        Rect.fromLTWH(last.left, last.top, last.width / 2, last.height),
        Rect.fromLTWH(
          last.left + last.width / 2,
          last.top,
          last.width / 2,
          last.height,
        ),
      ]);
    } else {
      cells.addAll([
        Rect.fromLTWH(last.left, last.top, last.width, last.height / 2),
        Rect.fromLTWH(
          last.left,
          last.top + last.height / 2,
          last.width,
          last.height / 2,
        ),
      ]);
    }
  }
  const g = previewGap;
  return [
    for (final c in cells)
      Rect.fromLTRB(
        c.left + (c.left <= 0.0001 ? g : g / 2),
        c.top + (c.top <= 0.0001 ? g : g / 2),
        c.right - (c.right >= 0.9999 ? g : g / 2),
        c.bottom - (c.bottom >= 0.9999 ? g : g / 2),
      ),
  ];
}
