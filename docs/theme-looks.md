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
| COSMIC | CosmicTk `monospace_font` | CosmicTk `interface_font` | Theme Builder `frosted` (strength) + `frosted_windows`, `frosted_panel`, `frosted_applets`, `frosted_system_interface`; helper rebuilds the Theme. Apply keeps the frosted fields. |
| KDE | kdeglobals `fixed` | kdeglobals `font` (`menuFont`, `toolBarFont` follow when they equalled it) | kwinrc `[Plugins] blurEnabled`, `[Effect-blur] BlurStrength`; KWin reconfigured |
| Omarchy | `omarchy font set` | – (no interface font in Omarchy) | Hyprland `decoration:blur:enabled`, `size`/`passes` from the strength |

Caps: `fonts` (mono), `uiFont`, `blur`. Missing caps hide the controls.

## Routes (maprisma-theme core)

- `looks.get {slug}` → `{look, own: {mono_font, ui_font, blur}, fonts, ui_fonts, caps}`
- `looks.set {slug, look}` → `{done, previous}`; when the theme is the one in use, it is applied
  again (only the changed parts).

## Blur on COSMIC

Helper `blur` prints the mode in use's `{strength 0..13, windows, system, panel, applets, maximized}`;
`set-blur <json>` changes any of those in the Theme Builder of both modes (a mode is only skipped when it
has no palette at all, as a default builder would carry the dark palette) and builds each Theme again.
A look's strength 1..15 maps to `round((s-1)*13/14)`; "on" sets windows, system, panel and applets,
maximized apps stay as the user set them. The user's own blur is the whole helper state (`own_blur`).

`apply --colors` / `--ron` keep the Theme Builder's desktop settings (gaps, active hint and its colour,
all frosted fields) from the mode in use: before, every theme apply reset them to COSMIC's defaults.

## Steps

1. Core: looks.json, routes, apply chain, interface font for COSMIC and KDE, `Cap.uiFont`.
2. COSMIC blur: helper `blur` / `set-blur`, apply keeps the desktop settings, `Cap.blur`.
3. KDE blur: kwinrc Blur effect, `Cap.blur`.
4. Flutter: the Font & effects dialog on theme cards and in the theme details.

Codex reviews each step (read-only); findings are verified before fixing.
