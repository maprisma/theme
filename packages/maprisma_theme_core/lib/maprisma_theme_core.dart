/// Maprisma Theme's core.
library;

export 'package:maprisma_core_kit/process.dart';

export 'src/apply.dart';
export 'src/colors.dart';
export 'src/context.dart';
export 'src/core.dart';
export 'src/desktop.dart';
export 'src/looks.dart';
export 'src/paths.dart';
export 'src/posix.dart';
export 'src/screenshot.dart';
export 'src/protocol.dart';
export 'src/settings.dart';
export 'src/shared_ai.dart';
export 'src/store.dart';
export 'src/themes.dart';
export 'src/cli.dart';
export 'src/daemon.dart' show runDaemon;
export 'src/workspace_state.dart'
    show workspaceSchema, presetNames, splitMin, splitMax, columnsSplitMax, cleanSplit, modeForPreset, presetForMode,
        builtinDefaultPreset, validPresetsForCap, isUnlimitedPreset, effectivePreset, effectiveSplit, presetConfigured,
        effectiveLimit, effectiveMode, workspaceModeNames;
export 'src/hyprland_wm.dart'
    show HyprWm, HyprCommand, HyprConnector, planPreset, parseHyprEvent, simpleTileConflict, workspaceRulesLua,
        hyprAddress, hyprAddressPattern, hyprFloatTag, BoundedLineSplitter, hyprEventLineMax;
export 'src/custom.dart'
    show derivedColors, mainKeys, paletteKeys, terminalKeys, moreKeys, baseColorKeys, colorLabel, isDarkBackground, createThemeFolder, maxNameLength;

export 'src/i18n.dart' show tr, trf, languageNames, languageSetting, systemLanguage, currentLanguage;
