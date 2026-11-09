# Theme looks: fonts and blur per theme

Asked 2026-11-09: "we should be able to change fonts per theme, even when it is already installed,
same for blur effects when available". The same design goes into the Omarchy Theme Manager plugin.

## What the user gets

- **Font & effects…** on every theme (system, imported, git, custom): the monospace font, the
  interface font (where the desktop has one) and blur (where the desktop has it).
- Each field has "Theme default" (= the theme's own value if it has one, else your own) or a value.
- Applying a theme uses its look; a theme without one gives the user's own values back (the
  `own_font` rule, extended to every field).

## Storage

`$config/looks.json` (beside settings.json, part of backups):

```json
{"tokyo-night": {"mono_font": "JetBrains Mono", "ui_font": "Inter", "blur": {"on": true, "strength": 8}}}
```

- Keys are theme slugs; a theme's entry with no field left is removed. Renaming a custom theme takes
  its look along; a deleted theme's look stays while Undo is offered and goes with `themes.forget`.
- `mono_font`, `ui_font`: an installed family name (the `fontRe` check). `blur.on`: bool;
  `blur.strength`: 1..15 (KWin's BlurStrength range; COSMIC's BlurStrength enum index + 1).
- Theme files are never changed: bundled and imported themes stay as they came; a custom theme's
  own `theme-manager.json` `font` stays its "own" font (the Editor still edits that one).

## Which value wins

look entry → the theme's own value (`theme-manager.json` `font`, later `ui_font`/`blur`) → the user's own.

The user's own value is saved the first time a theme changes that field and given back (then cleared)
when a theme without it is applied: settings `own_font` / `own_ui_font` / `own_blur` (+ `_kde`
variants; COSMIC keeps the unsuffixed names). `(default)` marks "the desktop default was in use".

## Desktops

| | mono font | interface font | blur |
| --- | --- | --- | --- |
| COSMIC | CosmicTk `monospace_font` | CosmicTk `interface_font` | Theme Builder `frosted` (strength) + `frosted_windows`, `frosted_panel`, `frosted_applets`, `frosted_system_interface`, per mode; helper rebuilds each Theme. Apply keeps them. |
| KDE | kdeglobals `fixed` | kdeglobals `font` (`menuFont`, `toolBarFont`, `[WM] activeFont` follow when they had its family; a receipt puts exactly those back) | kwinrc `[Plugins] blurEnabled`, `[Effect-blur] BlurStrength`; KWin loads the effect, reconfigured |
| Omarchy | `omarchy font set` | – (no interface font in Omarchy) | Hyprland `decoration:blur:enabled`, `size`/`passes` from the strength |

Caps: `fonts` (mono), `uiFont`, `blur`. Missing caps hide the controls.

## Routes (maprisma-theme core)

- `looks.get {slug}` → `{look, own: {mono_font, ui_font, blur}, fonts, ui_fonts, caps}`
- `looks.set {slug, look}` → `{done, previous}`; when the theme is the one in use, it is applied
  again (only the changed parts).

## Blur on COSMIC

Helper `blur` prints `{mode, dark, light}`: each mode's `{strength 0..13, windows, system, panel, applets,
maximized}` (COSMIC keeps them per mode; a mode with no palette anywhere, not even COSMIC's system
defaults, is null). `set-blur <json>` takes `{dark, light}` (each mode exactly as given) or one change for
both; each Theme is built again; when a write fails, the modes written before get their old builders back.
A look's strength 1..15 maps to `round((s-1)*13/14)`; "on" sets windows, system, panel and applets in both
modes, maximized apps stay as each mode has them. The user's own blur is the whole `blur` output
(`own_blur`), kept before the first change.

`apply --colors` / `--ron` keep the Theme Builder's desktop settings (gaps, active hint, blur) of the
theme's mode (else the mode in use): before, every theme apply reset them. A native RON theme keeps its own
hint colour; its frosted settings count as the theme's own blur (`ronBlur`), applied through the look chain.

## Blur on KDE

The state is kwinrc's raw `[Plugins] blurEnabled` and `[Effect-blur] BlurStrength` (null = missing) plus
whether KWin runs the effect now (`isEffectLoaded`): KWin's default for a missing key depends on the GPU.
Blur is offered only where `isEffectSupported blur` is true (OpenGL compositing). A change writes both keys,
loads or unloads the effect (checked) and `reconfigureEffect blur` reads the strength; when any of it fails,
keys and effect go back. Noise strength and saturation are never touched. Missing strength = 15 (blur.kcfg).
Blur shows only behind see-through surfaces (panel, menus, Konsole with opacity below 100 %).

## Steps

1. Core: looks.json, routes, apply chain, interface font for COSMIC and KDE, `Cap.uiFont`.
2. COSMIC blur: helper `blur` / `set-blur`, apply keeps the desktop settings, `Cap.blur`.
3. KDE blur: kwinrc Blur effect, `Cap.blur`.
4. Flutter: the Font & effects dialog on theme cards and in the theme details.

Codex reviews each step (read-only); findings are verified before fixing.
