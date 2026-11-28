import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/preview_geometry.dart';

void main() {
  const eps = 1e-9;

  group('constants and defaults', () {
    test('preset lists and split limits match PreviewLogic.js', () {
      expect(presetNames, const [
        'side-by-side',
        'stacked',
        'master-left',
        'master-right',
        'columns',
        'grid',
        'floating',
        'scrolling',
        'none',
      ]);
      expect(freePresets, const ['floating', 'scrolling']);
      expect(splitPresets, const [
        'master-left',
        'master-right',
        'side-by-side',
        'stacked',
        'columns',
      ]);
      expect(tilingByCap, const {
        1: ['side-by-side'],
        2: ['side-by-side', 'stacked'],
        3: ['columns', 'master-left', 'master-right'],
        4: ['columns', 'master-left', 'master-right', 'grid'],
      });
      expect(splitMin, 0.2);
      expect(splitMax, 0.8);
      expect(columnsSplitMax, 0.6);
      expect(previewGap, 0.035);
    });

    test('builtinDefaultPreset maps every cap accurately', () {
      expect(builtinDefaultPreset(1), 'side-by-side');
      expect(builtinDefaultPreset(2), 'side-by-side');
      expect(builtinDefaultPreset(3), 'master-left');
      expect(builtinDefaultPreset(4), 'grid');
      expect(builtinDefaultPreset(0), 'side-by-side');
      expect(builtinDefaultPreset(5), 'side-by-side');
    });

    test('isPresetCompatibleWithCap across all presets and caps 1..4', () {
      for (final cap in [1, 2, 3, 4]) {
        expect(isPresetCompatibleWithCap('none', cap), isTrue);
        expect(isPresetCompatibleWithCap('floating', cap), isTrue);
        expect(isPresetCompatibleWithCap('scrolling', cap), isTrue);
        expect(isPresetCompatibleWithCap('default', cap), isTrue);
        expect(isPresetCompatibleWithCap('tiled', cap), isTrue);
      }
      // Out-of-range caps
      expect(isPresetCompatibleWithCap('none', 0), isTrue);
      expect(isPresetCompatibleWithCap('floating', 0), isTrue);
      expect(isPresetCompatibleWithCap('scrolling', 0), isTrue);
      expect(isPresetCompatibleWithCap('tiled', 0), isFalse);
      expect(isPresetCompatibleWithCap('side-by-side', 0), isFalse);
      expect(isPresetCompatibleWithCap('grid', 5), isFalse);

      // Cap 1
      expect(isPresetCompatibleWithCap('side-by-side', 1), isTrue);
      expect(isPresetCompatibleWithCap('stacked', 1), isFalse);
      expect(isPresetCompatibleWithCap('master-left', 1), isFalse);
      expect(isPresetCompatibleWithCap('master-right', 1), isFalse);
      expect(isPresetCompatibleWithCap('columns', 1), isFalse);
      expect(isPresetCompatibleWithCap('grid', 1), isFalse);

      // Cap 2
      expect(isPresetCompatibleWithCap('side-by-side', 2), isTrue);
      expect(isPresetCompatibleWithCap('stacked', 2), isTrue);
      expect(isPresetCompatibleWithCap('master-left', 2), isFalse);
      expect(isPresetCompatibleWithCap('master-right', 2), isFalse);
      expect(isPresetCompatibleWithCap('columns', 2), isFalse);
      expect(isPresetCompatibleWithCap('grid', 2), isFalse);

      // Cap 3
      expect(isPresetCompatibleWithCap('columns', 3), isTrue);
      expect(isPresetCompatibleWithCap('master-left', 3), isTrue);
      expect(isPresetCompatibleWithCap('master-right', 3), isTrue);
      expect(isPresetCompatibleWithCap('side-by-side', 3), isFalse);
      expect(isPresetCompatibleWithCap('stacked', 3), isFalse);
      expect(isPresetCompatibleWithCap('grid', 3), isFalse);

      // Cap 4
      expect(isPresetCompatibleWithCap('columns', 4), isTrue);
      expect(isPresetCompatibleWithCap('master-left', 4), isTrue);
      expect(isPresetCompatibleWithCap('master-right', 4), isTrue);
      expect(isPresetCompatibleWithCap('grid', 4), isTrue);
      expect(isPresetCompatibleWithCap('side-by-side', 4), isFalse);
      expect(isPresetCompatibleWithCap('stacked', 4), isFalse);
    });
  });

  group('split range, clamping, and snapping', () {
    test('hasDivider matches PreviewLogic.js for every preset x cap', () {
      for (final cap in [1, 2, 3, 4]) {
        expect(hasDivider('grid', cap), isFalse);
        expect(hasDivider('floating', cap), isFalse);
        expect(hasDivider('scrolling', cap), isFalse);
        expect(hasDivider('none', cap), isFalse);
        expect(hasDivider('tiled', cap), isFalse);
        expect(hasDivider('default', cap), isFalse);
      }

      // columns divider only with 3 windows
      expect(hasDivider('columns', 1), isFalse);
      expect(hasDivider('columns', 2), isFalse);
      expect(hasDivider('columns', 3), isTrue);
      expect(hasDivider('columns', 4), isFalse);

      for (final p in ['side-by-side', 'stacked', 'master-left', 'master-right']) {
        expect(hasDivider(p, 1), isFalse);
        expect(hasDivider(p, 2), isTrue);
        expect(hasDivider(p, 3), isTrue);
        expect(hasDivider(p, 4), isTrue);
      }
    });

    test('splitRange distinguishes columns from other presets', () {
      expect(splitRange('columns'), (0.2, 0.6));
      for (final p in ['side-by-side', 'stacked', 'master-left', 'master-right', 'grid']) {
        expect(splitRange(p), (0.2, 0.8));
      }
    });

    test('clampSplit clamps to range and rounds to 2 decimals', () {
      expect(clampSplit('columns', 0.9), 0.6);
      expect(clampSplit('columns', 0.1), 0.2);
      expect(clampSplit('columns', 0.334), 0.33);
      expect(clampSplit('columns', 0.336), 0.34);
      expect(clampSplit('columns', double.nan), 0.33);

      expect(clampSplit('master-left', 0.9), 0.8);
      expect(clampSplit('master-left', 0.05), 0.2);
      expect(clampSplit('master-left', 0.624), 0.62);
      expect(clampSplit('master-left', 0.626), 0.63);
      expect(clampSplit('master-left', double.nan), 0.5);
      expect(clampSplit('side-by-side', double.infinity), 0.8);
      expect(clampSplit('side-by-side', double.negativeInfinity), 0.2);
    });

    test('snapSplit snaps within 0.025 of 0.50 or 1/3 -> 0.33 for columns', () {
      // Standard 2-region presets snap around 0.50
      expect(snapSplit('side-by-side', 0.50), 0.5);
      expect(snapSplit('side-by-side', 0.52), 0.5);
      expect(snapSplit('side-by-side', 0.48), 0.5);
      expect(snapSplit('side-by-side', 0.524), 0.5);
      expect(snapSplit('side-by-side', 0.476), 0.5);
      expect(snapSplit('side-by-side', 0.53), 0.53);
      expect(snapSplit('side-by-side', 0.47), 0.47);
      expect(snapSplit('master-right', 0.95), 0.8);
      expect(snapSplit('stacked', 0.1), 0.2);

      // 3-window columns snaps around 1/3 -> 0.33
      expect(snapSplit('columns', 1 / 3), 0.33);
      expect(snapSplit('columns', 0.33), 0.33);
      expect(snapSplit('columns', 0.35), 0.33);
      expect(snapSplit('columns', 0.31), 0.33);
      expect(snapSplit('columns', 0.36), 0.36);
      expect(snapSplit('columns', 0.30), 0.30);
      expect(snapSplit('columns', 0.8), 0.6);
      expect(snapSplit('columns', 0.05), 0.2);
      expect(snapSplit('columns', double.nan), 0.33);
    });
  });

  group('presetRects geometry for all 9 presets x caps 1..4', () {
    const g = previewGap;
    const half = (1 - 3 * g) / 2;

    test('count == 0 returns empty for all presets', () {
      for (final p in [...presetNames, 'tiled', 'default']) {
        expect(presetRects(p, 0), isEmpty, reason: 'preset=$p');
      }
    });

    test('cap == 1 returns single full rect for tiling presets, 3 for free/none', () {
      for (final p in [
        'side-by-side',
        'stacked',
        'master-left',
        'master-right',
        'columns',
        'grid',
      ]) {
        final rects = presetRects(p, 1);
        expect(rects, hasLength(1), reason: 'preset=$p');
        expect(rects[0].left, closeTo(g, eps));
        expect(rects[0].top, closeTo(g, eps));
        expect(rects[0].width, closeTo(1 - 2 * g, eps));
        expect(rects[0].height, closeTo(1 - 2 * g, eps));
      }

      for (final p in ['floating', 'scrolling', 'none']) {
        expect(presetRects(p, 1), hasLength(3), reason: 'preset=$p');
      }
    });

    test('side-by-side with default and custom split', () {
      final even = presetRects('side-by-side', 2);
      expect(even, hasLength(2));
      expect(even[0].left, closeTo(g, eps));
      expect(even[0].width, closeTo(half, eps));
      expect(even[1].left, closeTo(2 * g + half, eps));
      expect(even[1].width, closeTo(half, eps));
      expect(even[0].top, closeTo(even[1].top, eps));
      expect(even[1].right, closeTo(1 - g, eps));

      final split70 = presetRects('side-by-side', 2, split: 0.7);
      final first = (1 - 3 * g) * 0.7;
      final second = (1 - 3 * g) * 0.3;
      expect(split70[0].width, closeTo(first, eps));
      expect(split70[1].left, closeTo(2 * g + first, eps));
      expect(split70[1].width, closeTo(second, eps));
      expect(split70[1].left - split70[0].right, closeTo(g, eps));
    });

    test('stacked with default and custom split', () {
      final even = presetRects('stacked', 2);
      expect(even, hasLength(2));
      expect(even[0].top, closeTo(g, eps));
      expect(even[0].height, closeTo(half, eps));
      expect(even[1].top, closeTo(2 * g + half, eps));
      expect(even[1].height, closeTo(half, eps));
      expect(even[0].width, closeTo(1 - 2 * g, eps));
      expect(even[1].bottom, closeTo(1 - g, eps));

      final split30 = presetRects('stacked', 2, split: 0.3);
      final first = (1 - 3 * g) * 0.3;
      final second = (1 - 3 * g) * 0.7;
      expect(split30[0].height, closeTo(first, eps));
      expect(split30[1].top, closeTo(2 * g + first, eps));
      expect(split30[1].height, closeTo(second, eps));
    });

    test('master-left for caps 2, 3, 4 with default and custom split', () {
      for (final cap in [2, 3, 4]) {
        final rects = presetRects('master-left', cap, split: 0.6);
        expect(rects, hasLength(cap));
        final first = (1 - 3 * g) * 0.6;
        final second = (1 - 3 * g) * 0.4;
        // Master is index 0 on the left, full height
        expect(rects[0].left, closeTo(g, eps));
        expect(rects[0].width, closeTo(first, eps));
        expect(rects[0].height, closeTo(1 - 2 * g, eps));
        // Remaining windows stacked vertically on the right
        final stackCount = cap - 1;
        final expectedH = (1 - (stackCount + 1) * g) / stackCount;
        for (var i = 1; i < cap; i++) {
          expect(rects[i].left, closeTo(2 * g + first, eps));
          expect(rects[i].width, closeTo(second, eps));
          expect(rects[i].height, closeTo(expectedH, eps));
          if (i > 1) {
            expect(rects[i].top - rects[i - 1].bottom, closeTo(g, eps));
          }
        }
        expect(rects.last.bottom, closeTo(1 - g, eps));
      }
    });

    test('master-right for caps 2, 3, 4 with default and custom split', () {
      for (final cap in [2, 3, 4]) {
        final rects = presetRects('master-right', cap, split: 0.65);
        expect(rects, hasLength(cap));
        final first = (1 - 3 * g) * 0.65;
        final second = (1 - 3 * g) * 0.35;
        // Stacked windows come first on the left
        final stackCount = cap - 1;
        final expectedH = (1 - (stackCount + 1) * g) / stackCount;
        for (var i = 0; i < stackCount; i++) {
          expect(rects[i].left, closeTo(g, eps));
          expect(rects[i].width, closeTo(second, eps));
          expect(rects[i].height, closeTo(expectedH, eps));
        }
        // Master is last index on the right, full height
        expect(rects.last.left, closeTo(2 * g + second, eps));
        expect(rects.last.width, closeTo(first, eps));
        expect(rects.last.height, closeTo(1 - 2 * g, eps));
        expect(rects.last.right, closeTo(1 - g, eps));
      }
    });

    test('columns for caps 2, 3, 4 and 3-column split ratio', () {
      for (final cap in [2, 3, 4]) {
        final rects = presetRects('columns', cap);
        expect(rects, hasLength(cap));
        final w = (1 - (cap + 1) * g) / cap;
        for (var i = 0; i < cap; i++) {
          expect(rects[i].left, closeTo(g + i * (w + g), eps));
          expect(rects[i].width, closeTo(w, eps));
          expect(rects[i].height, closeTo(1 - 2 * g, eps));
        }
        expect(rects.last.right, closeTo(1 - g, eps));
      }

      // 3-window columns with split = 0.5 (matches test_preview_logic.js)
      final r = presetRects('columns', 3, split: 0.5);
      expect(r[1].width, closeTo((1 - 4 * g) * 0.5, eps));
      expect(r[0].width, closeTo(r[2].width, eps));
      expect(r[1].left - r[0].right, closeTo(g, eps));
      expect(r[2].left - r[1].right, closeTo(g, eps));
      expect(r[2].right, closeTo(1 - g, eps));

      // Split above columnsSplitMax is capped at 0.6
      final rCapped = presetRects('columns', 3, split: 0.9);
      expect(rCapped[1].width, closeTo((1 - 4 * g) * columnsSplitMax, eps));
      expect(rCapped[0].width, closeTo(rCapped[2].width, eps));

      // 4-window columns ignores split and stays even
      final r4 = presetRects('columns', 4, split: 0.5);
      for (final rect in r4) {
        expect(rect.width, closeTo((1 - 5 * g) / 4, eps));
      }
    });

    test('grid returns 2x2 even quadrants', () {
      for (final cap in [2, 3, 4]) {
        final rects = presetRects('grid', cap);
        expect(rects, hasLength(4));
        expect(rects[0], const Rect.fromLTWH(g, g, half, half));
        expect(rects[1], const Rect.fromLTWH(2 * g + half, g, half, half));
        expect(rects[2], const Rect.fromLTWH(g, 2 * g + half, half, half));
        expect(
          rects[3],
          const Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
        );
      }
    });

    test('floating, scrolling, and none match PreviewLogic.js exactly', () {
      for (final cap in [1, 2, 3, 4]) {
        expect(presetRects('floating', cap), const [
          Rect.fromLTWH(0.08, 0.12, 0.5, 0.5),
          Rect.fromLTWH(0.3, 0.28, 0.5, 0.5),
          Rect.fromLTWH(0.5, 0.08, 0.42, 0.42),
        ]);
        expect(presetRects('scrolling', cap), const [
          Rect.fromLTWH(g, g, 0.42, 1 - 2 * g),
          Rect.fromLTWH(2 * g + 0.42, g, 0.42, 1 - 2 * g),
          Rect.fromLTWH(3 * g + 0.84, g, 0.42, 1 - 2 * g),
        ]);
        expect(presetRects('none', cap), const [
          Rect.fromLTWH(g, g, half, 1 - 2 * g),
          Rect.fromLTWH(2 * g + half, g, half, half),
          Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
        ]);
      }
    });

    test('every preset x cap 1..4 produces non-empty positive-sized rects', () {
      for (final p in [...presetNames, 'tiled', 'default']) {
        for (final cap in [1, 2, 3, 4]) {
          final rects = presetRects(p, cap);
          expect(rects, isNotEmpty, reason: 'preset=$p cap=$cap');
          for (final r in rects) {
            expect(r.width, greaterThan(0), reason: 'preset=$p cap=$cap');
            expect(r.height, greaterThan(0), reason: 'preset=$p cap=$cap');
          }
        }
      }
    });
  });

  group('COSMIC/KDE tiled and default autotile modes', () {
    test('splits newest window along its longer side at 16:9 aspect', () {
      for (final mode in ['tiled', 'default']) {
        expect(presetRects(mode, 0), isEmpty);

        final one = presetRects(mode, 1);
        expect(one, hasLength(1));
        expect(one[0].left, closeTo(previewGap, eps));
        expect(one[0].right, closeTo(1 - previewGap, eps));

        final two = presetRects(mode, 2);
        expect(two, hasLength(2));
        expect(two[0].top, closeTo(two[1].top, eps));
        expect(two[1].left, greaterThan(two[0].right));

        final three = presetRects(mode, 3);
        expect(three, hasLength(3));
        expect(three[1].left, closeTo(three[2].left, eps));
        expect(three[2].top, greaterThan(three[1].bottom));

        final four = presetRects(mode, 4);
        expect(four, hasLength(4));
        expect(four[2].top, closeTo(four[3].top, eps));
        expect(four[3].left, greaterThan(four[2].right));
      }
    });

    test('respects portrait aspect ratio and clamps count at 8', () {
      final portraitTwo = presetRects('tiled', 2, aspect: 9 / 16);
      expect(portraitTwo, hasLength(2));
      // Tall screen splits top/bottom first
      expect(portraitTwo[0].left, closeTo(portraitTwo[1].left, eps));
      expect(portraitTwo[1].top, greaterThan(portraitTwo[0].bottom));

      expect(presetRects('tiled', 12), hasLength(8));
    });
  });

  group('presetDivider, hitTest, and splitFromPointer', () {
    test('returns null when preset has no divider', () {
      expect(presetDivider('side-by-side', 1), isNull);
      expect(presetDivider('columns', 2), isNull);
      expect(presetDivider('columns', 4), isNull);
      expect(presetDivider('grid', 4), isNull);
      expect(presetDivider('floating', 3), isNull);
      expect(presetDivider('scrolling', 3), isNull);
      expect(presetDivider('none', 3), isNull);
      expect(presetDivider('tiled', 3), isNull);
      expect(presetDivider('default', 3), isNull);
    });

    test('divider sits exactly in the center of the gap between windows', () {
      // side-by-side
      final sbsRects = presetRects('side-by-side', 2, split: 0.62);
      final sbsDiv = presetDivider('side-by-side', 2, split: 0.62)!;
      expect(sbsDiv.vertical, isTrue);
      expect(sbsDiv.fromRight, isFalse);
      expect(sbsDiv.secondaryPos, isNull);
      expect(sbsDiv.pos, closeTo((sbsRects[0].right + sbsRects[1].left) / 2, eps));
      expect(sbsDiv.start, closeTo(previewGap, eps));
      expect(sbsDiv.end, closeTo(1 - previewGap, eps));

      // stacked
      final stkRects = presetRects('stacked', 2, split: 0.35);
      final stkDiv = presetDivider('stacked', 2, split: 0.35)!;
      expect(stkDiv.vertical, isFalse);
      expect(stkDiv.fromRight, isFalse);
      expect(stkDiv.pos, closeTo((stkRects[0].bottom + stkRects[1].top) / 2, eps));

      // master-left
      final mlRects = presetRects('master-left', 3, split: 0.6);
      final mlDiv = presetDivider('master-left', 3, split: 0.6)!;
      expect(mlDiv.vertical, isTrue);
      expect(mlDiv.fromRight, isFalse);
      expect(mlDiv.pos, closeTo((mlRects[0].right + mlRects[1].left) / 2, eps));

      // master-right
      final mrRects = presetRects('master-right', 3, split: 0.65);
      final mrDiv = presetDivider('master-right', 3, split: 0.65)!;
      expect(mrDiv.vertical, isTrue);
      expect(mrDiv.fromRight, isTrue);
      expect(mrDiv.pos, closeTo((mrRects[0].right + mrRects.last.left) / 2, eps));

      // columns (3 windows) has two symmetric dividers
      final colRects = presetRects('columns', 3, split: 0.45);
      final colDiv = presetDivider('columns', 3, split: 0.45)!;
      expect(colDiv.vertical, isTrue);
      expect(colDiv.fromRight, isFalse);
      expect(colDiv.secondaryPos, isNotNull);
      expect(colDiv.positions, hasLength(2));
      expect(colDiv.pos, closeTo((colRects[0].right + colRects[1].left) / 2, eps));
      expect(
        colDiv.secondaryPos!,
        closeTo((colRects[1].right + colRects[2].left) / 2, eps),
      );
      expect(colDiv.pos + colDiv.secondaryPos!, closeTo(1.0, eps));
    });

    test('hitTest detects pointer on primary and secondary dividers', () {
      final sbs = presetDivider('side-by-side', 2)!;
      expect(sbs.hitTest(sbs.pos, 0.5), isTrue);
      expect(sbs.hitTest(sbs.pos + 0.01, 0.5), isTrue);
      expect(sbs.hitTest(sbs.pos + 0.1, 0.5), isFalse);
      expect(sbs.hitTest(sbs.pos, 0.01), isFalse); // outside vertical span

      final stk = presetDivider('stacked', 2)!;
      expect(stk.hitTest(0.5, stk.pos), isTrue);
      expect(stk.hitTest(0.5, stk.pos + 0.1), isFalse);
      expect(stk.hitTest(0.01, stk.pos), isFalse); // outside horizontal span

      final col = presetDivider('columns', 3, split: 0.5)!;
      expect(col.hitTest(col.pos, 0.5), isTrue);
      expect(col.hitTest(col.secondaryPos!, 0.5), isTrue);
      expect(col.hitTest(0.5, 0.5), isFalse);
    });

    test('splitFromPointer round-trips presetDivider for all split presets', () {
      for (final preset in ['side-by-side', 'master-left', 'master-right']) {
        for (final target in [0.2, 0.35, 0.5, 0.65, 0.8]) {
          final div = presetDivider(preset, 3, split: target)!;
          final recovered = splitFromPointer(preset, div.pos, 0.5);
          expect(recovered, closeTo(target, eps), reason: '$preset@$target');
        }
      }

      for (final target in [0.2, 0.35, 0.5, 0.65, 0.8]) {
        final div = presetDivider('stacked', 2, split: target)!;
        final recovered = splitFromPointer('stacked', 0.5, div.pos);
        expect(recovered, closeTo(target, eps), reason: 'stacked@$target');
      }

      // 3-window columns round-trips from BOTH left and right dividers
      for (final target in [0.2, 0.33, 0.45, 0.6]) {
        final div = presetDivider('columns', 3, split: target)!;
        expect(
          splitFromPointer('columns', div.pos, 0.5),
          closeTo(target, eps),
          reason: 'columns-left@$target',
        );
        expect(
          splitFromPointer('columns', div.secondaryPos!, 0.5),
          closeTo(target, eps),
          reason: 'columns-right@$target',
        );
      }

      // Snapping and clamping during pointer drag
      expect(splitFromPointer('side-by-side', 0.51, 0.5), 0.5);
      expect(splitFromPointer('side-by-side', 0.0, 0.5), splitMin);
      expect(splitFromPointer('side-by-side', 1.0, 0.5), splitMax);
      expect(splitFromPointer('master-right', 0.0, 0.5), splitMax);
      expect(splitFromPointer('master-right', 1.0, 0.5), splitMin);
      expect(splitFromPointer('columns', 0.5, 0.5), splitMin);
      expect(splitFromPointer('columns', 0.0, 0.5), columnsSplitMax);
      expect(splitFromPointer('columns', 1.0, 0.5), columnsSplitMax);
    });

    test('DividerInfo equality and hashCode', () {
      final a = presetDivider('columns', 3, split: 0.45);
      final b = presetDivider('columns', 3, split: 0.45);
      final c = presetDivider('columns', 3, split: 0.5);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('DividerInfo'));
    });
  });

  group('addZonePreset', () {
    test('matches test_preview_logic.js expectations', () {
      expect(addZonePreset(2, 0.5, 0.05), 'stacked');
      expect(addZonePreset(2, 0.05, 0.5), 'side-by-side');
      expect(addZonePreset(3, 0.1, 0.5), 'master-left');
      expect(addZonePreset(3, 0.9, 0.5), 'master-right');
      expect(addZonePreset(3, 0.5, 0.1), 'columns');
      expect(addZonePreset(3, 0.1, 0.1), 'master-left');
      expect(addZonePreset(4, 0.1, 0.1), 'grid');
      expect(addZonePreset(4, -3, 9), 'grid');
      expect(addZonePreset(1, 0.5, 0.5), isNull);
      expect(addZonePreset(0, 0.5, 0.5), isNull);
    });

    test('always produces a valid tiling preset for caps 2..4', () {
      for (final cap in [2, 3, 4]) {
        for (final u in [0.0, 0.2, 0.5, 0.8, 1.0]) {
          for (final v in [0.0, 0.2, 0.5, 0.8, 1.0]) {
            final preset = addZonePreset(cap, u, v);
            expect(tilingByCap[cap], contains(preset));
          }
        }
      }
    });
  });
}
