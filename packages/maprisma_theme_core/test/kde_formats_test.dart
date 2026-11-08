import 'dart:io';

import 'package:maprisma_theme_core/src/colors.dart';
import 'package:maprisma_theme_core/src/kde_formats.dart';
import 'package:test/test.dart';

const colorKeys = [
  'BackgroundNormal',
  'BackgroundAlternate',
  'DecorationFocus',
  'DecorationHover',
  'ForegroundActive',
  'ForegroundInactive',
  'ForegroundLink',
  'ForegroundNegative',
  'ForegroundNeutral',
  'ForegroundNormal',
  'ForegroundPositive',
  'ForegroundVisited',
];
const groups = [
  'Button',
  'Complementary',
  'Header',
  'Header][Inactive',
  'Selection',
  'Tooltip',
  'View',
  'Window',
];

void main() {
  for (final light in [false, true]) {
    test(
      'minimal ${light ? 'light' : 'dark'} colors.toml renders both formats',
      () {
        final temp = Directory.systemTemp.createTempSync('maprisma-kde-');
        addTearDown(() => temp.deleteSync(recursive: true));
        final file = File('${temp.path}/colors.toml')
          ..writeAsStringSync('''
accent = "#4488cc"
background = "${light ? '#f4f4f4' : '#161616'}"
foreground = "${light ? '#202020' : '#eeeeee'}"
red = "#bb4444"
green = "#44aa55"
yellow = "#bb9922"
blue = "#4488cc"
magenta = "#aa55bb"
cyan = "#33aaaa"
''');
        final resolved = resolveColors(
          parseColorsToml(file.readAsStringSync()),
        );
        String render(String path) {
          final result = renderKdeScheme(
            File('../../templates/$path').readAsStringSync(),
            resolved,
            'Maprisma',
          );
          expect(result, isNotNull);
          expect(result, isNot(contains('{{')));
          expect(result, isNot(contains('@SCHEME_NAME@')));
          return result!;
        }

        final plasma = render('kde.colors.tpl');
        for (final group in groups) {
          for (final key in colorKeys) {
            expect(
              iniValue(plasma, 'Colors:$group', key),
              matches(r'^\d+,\d+,\d+$'),
              reason: '$group/$key',
            );
          }
        }
        for (final group in ['Disabled', 'Inactive']) {
          for (final key in [
            'Color',
            'ColorAmount',
            'ColorEffect',
            'ContrastAmount',
            'ContrastEffect',
            'IntensityAmount',
            'IntensityEffect',
          ]) {
            expect(iniValue(plasma, 'ColorEffects:$group', key), isNotNull);
          }
        }
        expect(iniValue(plasma, 'General', 'Name'), 'Maprisma');
        expect(iniValue(plasma, 'General', 'ColorScheme'), 'Maprisma');
        expect(iniValue(plasma, 'KDE', 'contrast'), '4');
        for (final key in [
          'activeBackground',
          'activeForeground',
          'activeBlend',
          'inactiveBackground',
          'inactiveForeground',
          'inactiveBlend',
        ]) {
          expect(iniValue(plasma, 'WM', key), matches(r'^\d+,\d+,\d+$'));
        }
        expect(kdeCurrentLook(plasma)!['is_dark'], !light);
        final konsole = render('konsole.colorscheme.tpl');
        for (final group in [
          'Background',
          'Foreground',
          ...List.generate(8, (i) => 'Color$i'),
        ]) {
          for (final suffix in ['', 'Intense', 'Faint']) {
            expect(
              iniValue(konsole, '$group$suffix', 'Color'),
              matches(r'^\d+,\d+,\d+$'),
            );
          }
        }
        final palette = colorsObject(resolved);
        final names = [
          'black',
          'red',
          'green',
          'yellow',
          'blue',
          'magenta',
          'cyan',
          'white',
        ];
        String rgb(String hex) {
          final (r, g, b) = rgbOf(hex);
          return '$r,$g,$b';
        }

        for (var i = 0; i < 8; i++) {
          expect(
            iniValue(konsole, 'Color$i', 'Color'),
            rgb(palette[names[i]]!),
          );
          expect(
            iniValue(konsole, 'Color${i}Intense', 'Color'),
            rgb(palette['bright_${names[i]}']!),
          );
          expect(
            iniValue(konsole, 'Color${i}Faint', 'Color'),
            rgb(mixColor(palette[names[i]]!, palette['background']!, .3)),
          );
        }
        expect(iniValue(konsole, 'General', 'Description'), 'Maprisma');
        expect(iniValue(konsole, 'General', 'Opacity'), '1');
        expect(iniValue(konsole, 'General', 'Blur'), 'false');
      },
    );
  }

  test('scheme render failure and sanitized name', () {
    expect(renderKdeScheme('{{ missing }}', {}, 'Name'), isNull);
    expect(renderKdeScheme('Name=@SCHEME_NAME@', {}, 'A\r\n[B]=C'), 'Name=ABC');
  });

  test('INI preserves comments, spacing, CRLF, unknown and nested groups', () {
    const original =
        '# comment\r\n[General]\r\n  Name = Old  \r\nMystery=abc=xyz\r\n\r\n[Colors:Header][Inactive]\r\nName=Nested\r\n; keep\r\n[Other]\r\nThing=42';
    expect(iniValue(original, 'General', 'Mystery'), 'abc=xyz');
    expect(iniValue(original, 'Colors:Header][Inactive', 'Name'), 'Nested');
    expect(iniValue(original, 'Missing', 'Name'), isNull);
    expect(
      setIniValue(original, 'General', 'Name', 'New'),
      original.replaceFirst('Old', 'New'),
    );
    expect(
      setIniValue(original, 'Colors:Header][Inactive', 'Name', 'New'),
      original.replaceFirst('Nested', 'New'),
    );
    expect(
      setIniValue(original, 'General', 'Added', 'yes'),
      original.replaceFirst('[Colors:Header]', 'Added=yes\r\n[Colors:Header]'),
    );
    expect(
      setIniValue(original, 'Other', 'Added', 'yes'),
      '$original\r\nAdded=yes\r\n',
    );
    expect(
      setIniValue(original, 'New', 'K', 'V'),
      '$original\r\n[New]\r\nK=V\r\n',
    );
    expect(
      setIniValue(null, 'General', 'Name', 'New'),
      '[General]\nName=New\n',
    );
    expect(setIniValue('[G]\nx=1\nx=2\n', 'G', 'x', '3'), '[G]\nx=3\nx=3\n');
  });

  test('QFont family edit preserves all Qt5 and Qt6 fields', () {
    for (final old in [
      'Hack,10,-1,5,50,0,0,0,0,0',
      'Hack,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1',
    ]) {
      expect(qfontFamily(old), 'Hack');
      expect(
        qfontWithFamily(old, 'JetBrains Mono'),
        old.replaceFirst('Hack', 'JetBrains Mono'),
      );
    }
    for (final bad in [null, '', 'Hack', 'Hack,nan,-1,5,400,0,0,0,0,0']) {
      expect(qfontFamily(bad), isNull);
      expect(
        qfontWithFamily(bad, 'Mono'),
        'Mono,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1',
      );
    }
    expect(() => qfontWithFamily(null, 'A,B'), throwsArgumentError);
  });

  test('current look RGB, RGBA, fallback and missing/invalid colors', () {
    const base =
        '[Colors:Window]\nBackgroundNormal=16,32,48,255\nForegroundNormal=240,241,242\n[Colors:Selection]\nBackgroundNormal=1,2,3\n';
    expect(kdeCurrentLook(base), {
      'colors': {
        'background': '#102030',
        'foreground': '#f0f1f2',
        'accent': '#010203',
      },
      'is_dark': true,
      'corner_radius': null,
    });
    expect(
      kdeCurrentLook(
        '$base[General]\nAccentColor=10,20,30,128\n',
      )!['colors']['accent'],
      '#0a141e',
    );
    expect(
      kdeCurrentLook('$base[General]\nAccentColor=bad\n')!['colors']['accent'],
      '#010203',
    );
    expect(
      kdeCurrentLook(
        base.replaceFirst('16,32,48,255', '250,250,250'),
      )!['is_dark'],
      false,
    );
    for (final bad in [
      '',
      base.replaceFirst('ForegroundNormal', 'Unknown'),
      base.replaceFirst('BackgroundNormal=1,2,3', 'Unknown=1,2,3'),
      base.replaceFirst('16,32,48,255', '256,0,0'),
      base.replaceFirst('16,32,48,255', '1,2'),
      base.replaceFirst('16,32,48,255', '1,2,3,no'),
    ]) {
      expect(kdeCurrentLook(bad), isNull);
    }
  });

  test('Konsole profiles preserve settings and only new profiles get Parent', () {
    const old =
        '# keep\n[General]\nName=Old\nParent=Custom/\nCommand=/bin/fish\n[Appearance]\nColorScheme=Old\nFont=Hack,10\n[Unknown]\nKey=value\n';
    expect(
      konsoleProfile(old, 'New', 'Maprisma2'),
      old
          .replaceFirst('Name=Old', 'Name=New')
          .replaceFirst('ColorScheme=Old', 'ColorScheme=Maprisma2'),
    );
    final fresh = konsoleProfile(null, 'Maprisma', 'Maprisma1');
    expect(iniValue(fresh, 'General', 'Parent'), 'FALLBACK/');
    expect(iniValue(fresh, 'General', 'Name'), 'Maprisma');
    expect(iniValue(fresh, 'Appearance', 'ColorScheme'), 'Maprisma1');
    expect(
      iniValue(
        konsoleProfile('[General]\nName=Old\n', 'New', 'Scheme'),
        'General',
        'Parent',
      ),
      isNull,
    );
  });
}
