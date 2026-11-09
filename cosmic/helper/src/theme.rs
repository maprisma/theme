use crate::{Result, read_bounded};
use cosmic_config::{ConfigGet, CosmicConfigEntry};
use cosmic_theme::{CosmicPalette, Roundness, Theme, ThemeBuilder, ThemeMode};
use palette::{Srgb, Srgba};
use serde_json::{Value, json};
use std::path::Path;

pub fn rgb(value: &str) -> Result<Srgb> {
    if value.len() != 7
        || !value.starts_with('#')
        || !value[1..].bytes().all(|c| c.is_ascii_hexdigit())
    {
        return Err(format!("invalid color: {value}"));
    }
    let n = u32::from_str_radix(&value[1..], 16).map_err(|e| e.to_string())?;
    Ok(Srgb::new(
        ((n >> 16) & 255) as f32 / 255.,
        ((n >> 8) & 255) as f32 / 255.,
        (n & 255) as f32 / 255.,
    ))
}
fn color(v: &Value, key: &str) -> Result<Option<Srgb>> {
    v.get(key)
        .map(|v| {
            v.as_str()
                .ok_or_else(|| format!("{key} must be a color"))
                .and_then(rgb)
        })
        .transpose()
}
pub fn dark(v: &Value) -> Result<bool> {
    match v.get("mode").and_then(Value::as_str) {
        Some("dark") => Ok(true),
        Some("light") => Ok(false),
        Some(_) => Err("mode must be dark or light".into()),
        None => {
            let c = color(v, "background")?
                .unwrap_or(Srgb::new(0., 0., 0.))
                .into_linear();
            Ok(c.red * 0.2126 + c.green * 0.7152 + c.blue * 0.0722 < 0.5)
        }
    }
}
pub fn colors_file(path: &Path) -> Result<Value> {
    let v: Value = serde_json::from_str(&read_bounded(path)?).map_err(|e| e.to_string())?;
    if !v.is_object() {
        return Err("expected colors object".into());
    }
    for (k, v) in v.as_object().unwrap() {
        if k != "mode" && k != "corner" {
            rgb(v.as_str().ok_or("expected hex color")?)?;
        }
    }
    if v.get("mode").is_some_and(|m| !m.is_string()) {
        return Err("mode must be dark or light".into());
    }
    if v.get("corner")
        .is_some_and(|c| !c.is_null() && !c.is_string())
    {
        return Err("corner must be a string or null".into());
    }
    dark(&v)?;
    Ok(v)
}
pub fn builder(v: &Value) -> Result<ThemeBuilder> {
    let is_dark = dark(v)?;
    let mut b = if is_dark {
        ThemeBuilder::dark()
    } else {
        ThemeBuilder::light()
    };
    b.bg_color = color(v, "background")?.map(|c| Srgba::new(c.red, c.green, c.blue, 1.));
    b.neutral_tint = color(v, "background")?;
    b.text_tint = color(v, "foreground")?;
    b.accent = color(v, "accent")?;
    macro_rules! map {
        ($key:literal,$field:ident) => {
            if let Some(c) = color(v, $key)? {
                b.palette.as_mut().$field = Srgba::new(c.red, c.green, c.blue, 1.);
            }
        };
    }
    map!("blue", accent_blue);
    map!("red", accent_red);
    map!("green", accent_green);
    map!("yellow", accent_yellow);
    b.corner_radii = match v.get("corner").and_then(Value::as_str) {
        Some("round") => Roundness::Round.into(),
        Some("slightly_round") => Roundness::SlightlyRound.into(),
        Some("square") => Roundness::Square.into(),
        None => b.corner_radii,
        Some(_) => return Err("invalid corner".into()),
    };
    Ok(b)
}
pub fn ron_builder(path: &Path, mode: Option<&str>) -> Result<ThemeBuilder> {
    let mut b: ThemeBuilder = ron::from_str(&read_bounded(path)?).map_err(|e| e.to_string())?;
    if let Some(mode) = mode {
        let p = b.palette.inner();
        b.palette = match mode {
            "dark" => CosmicPalette::Dark(p),
            "light" => CosmicPalette::Light(p),
            _ => return Err("invalid mode".into()),
        };
    }
    Ok(b)
}
pub fn apply(b: ThemeBuilder) -> Result<Value> {
    let dark = b.palette.is_dark();
    let bc = if dark {
        ThemeBuilder::dark_config()
    } else {
        ThemeBuilder::light_config()
    }
    .map_err(|e| e.to_string())?;
    let tc = if dark {
        Theme::dark_config()
    } else {
        Theme::light_config()
    }
    .map_err(|e| e.to_string())?;
    b.write_entry(&bc).map_err(|e| e.to_string())?;
    b.build().write_entry(&tc).map_err(|e| e.to_string())?;
    use cosmic_config::ConfigSet;
    ThemeMode::config()
        .map_err(|e| e.to_string())?
        .set("is_dark", dark)
        .map_err(|e| e.to_string())?;
    Ok(json!({"applied":true,"mode":if dark {"dark"}else{"light"}}))
}
fn is_dark_now() -> bool {
    ThemeMode::config()
        .ok()
        .and_then(|c| c.get::<bool>("is_dark").ok())
        .unwrap_or(true)
}
fn builder_config(dark: bool) -> Result<cosmic_config::Config> {
    if dark {
        ThemeBuilder::dark_config()
    } else {
        ThemeBuilder::light_config()
    }
    .map_err(|e| e.to_string())
}
/// The Theme Builder COSMIC has for a mode, or None when that mode was never
/// written (no palette: a default builder would carry the dark palette).
fn stored_builder(dark: bool) -> Option<ThemeBuilder> {
    let c = builder_config(dark).ok()?;
    c.get::<CosmicPalette>("palette").ok()?;
    Some(ThemeBuilder::get_entry(&c).unwrap_or_else(|(_, b)| b))
}
/// The settings in the Theme Builder that belong to the desktop, not to a
/// theme: window gaps, the active window hint and blur ("frosted"). A theme
/// brings colours; these stay as the user (or a look) set them.
/// A theme's own active hint colour (a native RON theme can have one) stays;
/// its blur is applied afterwards as the theme's look (docs/theme-looks.md).
/// Each mode keeps its own (as COSMIC does): the settings come from the
/// theme's mode, else from the mode in use.
pub fn keep_desktop_settings(b: &mut ThemeBuilder) {
    let Some(cur) = stored_builder(b.palette.is_dark()).or_else(|| stored_builder(is_dark_now())) else {
        return;
    };
    b.gaps = cur.gaps;
    b.active_hint = cur.active_hint;
    if b.window_hint.is_none() {
        b.window_hint = cur.window_hint;
    }
    copy_blur(&cur, b);
}
fn copy_blur(from: &ThemeBuilder, to: &mut ThemeBuilder) {
    to.frosted = from.frosted;
    to.frosted_windows = from.frosted_windows;
    to.frosted_system_interface = from.frosted_system_interface;
    to.frosted_panel = from.frosted_panel;
    to.frosted_applets = from.frosted_applets;
    to.frosted_maximized_apps = from.frosted_maximized_apps;
}
fn blur_json(b: &ThemeBuilder) -> Value {
    json!({"strength":b.frosted as u8,"windows":b.frosted_windows,"system":b.frosted_system_interface,
        "panel":b.frosted_panel,"applets":b.frosted_applets,"maximized":b.frosted_maximized_apps})
}
fn mode_builder(dark: bool) -> ThemeBuilder {
    stored_builder(dark).unwrap_or_else(|| {
        if dark {
            ThemeBuilder::dark()
        } else {
            ThemeBuilder::light()
        }
    })
}
/// COSMIC's blur per mode (each keeps its own): strength 0..13
/// (BlurStrength) and where it is used; a mode never written is null,
/// unless it is the one in use.
pub fn blur() -> Value {
    let now = is_dark_now();
    let of = |dark: bool| match stored_builder(dark) {
        Some(b) => blur_json(&b),
        None if dark == now => blur_json(&mode_builder(dark)),
        None => Value::Null,
    };
    json!({"mode":if now {"dark"} else {"light"},"dark":of(true),"light":of(false)})
}
fn check_patch(v: &Value) -> Result<&serde_json::Map<String, Value>> {
    let o = v.as_object().ok_or("blur must be an object")?;
    for (k, x) in o {
        match k.as_str() {
            "strength" => {
                x.as_u64().filter(|n| *n <= 13).ok_or("strength must be 0..13")?;
            }
            "windows" | "system" | "panel" | "applets" | "maximized" => {
                x.as_bool().ok_or_else(|| format!("{k} must be true or false"))?;
            }
            _ => return Err(format!("unknown key {k}")),
        }
    }
    Ok(o)
}
fn patch(b: &mut ThemeBuilder, o: &serde_json::Map<String, Value>) {
    if let Some(s) = o
        .get("strength")
        .and_then(Value::as_u64)
        .and_then(|n| cosmic_theme::BlurStrength::try_from(n as u8).ok())
    {
        b.frosted = s;
    }
    let flag = |k: &str| o.get(k).and_then(Value::as_bool);
    if let Some(x) = flag("windows") {
        b.frosted_windows = x;
    }
    if let Some(x) = flag("system") {
        b.frosted_system_interface = x;
    }
    if let Some(x) = flag("panel") {
        b.frosted_panel = x;
    }
    if let Some(x) = flag("applets") {
        b.frosted_applets = x;
    }
    if let Some(x) = flag("maximized") {
        b.frosted_maximized_apps = x;
    }
}
fn write_mode(dark: bool, b: &ThemeBuilder) -> Result<()> {
    let tc = if dark {
        Theme::dark_config()
    } else {
        Theme::light_config()
    }
    .map_err(|e| e.to_string())?;
    b.write_entry(&builder_config(dark)?).map_err(|e| e.to_string())?;
    b.clone().build().write_entry(&tc).map_err(|e| e.to_string())
}
/// Changes blur and builds each Theme again, as COSMIC Settings does.
/// `{"dark": {..}, "light": {..}}` sets each mode as given (a missing or
/// null mode stays); any other object is one change for both modes (each
/// keeps the keys it leaves out). A mode never written is only touched when
/// it is the one in use. When a write fails, the modes written before get
/// their old builders back.
pub fn set_blur(v: &Value) -> Result<Value> {
    let o = v.as_object().ok_or("blur must be an object")?;
    let per_mode = o.contains_key("dark") || o.contains_key("light");
    if per_mode && o.keys().any(|k| k != "dark" && k != "light") {
        return Err("give dark and light, or one change".into());
    }
    let now = is_dark_now();
    let mut plan = Vec::new();
    for dark in [now, !now] {
        let change = if per_mode {
            match o.get(if dark { "dark" } else { "light" }) {
                None | Some(Value::Null) => continue,
                Some(x) => check_patch(x)?,
            }
        } else {
            check_patch(v)?
        };
        let old = match stored_builder(dark) {
            Some(b) => b,
            None if dark == now => mode_builder(dark),
            None => continue,
        };
        let mut b = old.clone();
        patch(&mut b, change);
        plan.push((dark, old, b));
    }
    if plan.is_empty() || o.is_empty() {
        return Err("nothing to change".into());
    }
    for i in 0..plan.len() {
        if let Err(e) = write_mode(plan[i].0, &plan[i].2) {
            for (dark, old, _) in &plan[..i] {
                let _ = write_mode(*dark, old);
            }
            return Err(e);
        }
    }
    Ok(blur())
}
pub fn current_theme() -> Theme {
    let dark = ThemeMode::config()
        .ok()
        .and_then(|c| c.get::<bool>("is_dark").ok())
        .unwrap_or(true);
    let config = if dark {
        Theme::dark_config()
    } else {
        Theme::light_config()
    };
    config
        .ok()
        .map(|c| Theme::get_entry(&c).unwrap_or_else(|(_, t)| t))
        .unwrap_or_else(|| {
            if dark {
                Theme::dark_default()
            } else {
                Theme::light_default()
            }
        })
}
fn hex(c: Srgba) -> String {
    format!(
        "#{:02x}{:02x}{:02x}",
        (c.red.clamp(0., 1.) * 255.).round() as u8,
        (c.green.clamp(0., 1.) * 255.).round() as u8,
        (c.blue.clamp(0., 1.) * 255.).round() as u8
    )
}
pub fn colors(t: &Theme) -> Value {
    let p = &t.palette;
    let mut v = json!({"mode":if t.is_dark {"dark"}else{"light"},"background":hex(t.bg_color()),"foreground":hex(t.on_bg_color()),"accent":hex(t.accent.base),"selection":hex(t.primary(false).component.selected),"muted":hex(p.neutral_5),"cursor":hex(t.on_bg_color()),"orange":hex(p.accent_orange),"corner":null});
    for (name, c) in [
        ("black", p.neutral_1),
        ("red", p.accent_red),
        ("green", p.accent_green),
        ("yellow", p.accent_yellow),
        ("blue", p.accent_blue),
        ("magenta", p.accent_purple),
        ("cyan", p.accent_blue),
        ("white", p.neutral_9),
    ] {
        v[name] = json!(hex(c));
        v[format!("bright_{name}")] = json!(hex(c));
    }
    v
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mapping() {
        let b=builder(&json!({"mode":"light","background":"#ffffff","foreground":"#222222","accent":"#336699","red":"#ff0000","corner":"square"})).unwrap();
        assert!(!b.palette.is_dark());
        assert_eq!(b.bg_color.unwrap().red, 1.);
        assert_eq!(b.accent.unwrap(), rgb("#336699").unwrap());
        assert_eq!(b.palette.as_ref().accent_red.red, 1.);
        assert_eq!(b.corner_radii.radius_s, [2.; 4]);
    }
    #[test]
    fn omitted_colors_keep_defaults_and_mode_uses_luminance() {
        let dark = builder(&json!({"background":"#101010"})).unwrap();
        assert!(dark.palette.is_dark());
        assert_eq!(dark.palette, ThemeBuilder::dark().palette);
        assert_eq!(dark.accent, None);
        assert!(
            !builder(&json!({"background":"#ffffff"}))
                .unwrap()
                .palette
                .is_dark()
        );
        assert!(rgb("#ff00zz").is_err());
        assert!(rgb("red").is_err());
    }
    #[test]
    fn blur_json_uses_the_strength_index() {
        let mut b = ThemeBuilder::dark();
        b.frosted = cosmic_theme::BlurStrength::High;
        b.frosted_panel = true;
        let v = blur_json(&b);
        assert_eq!(v["strength"], 8);
        assert_eq!(v["panel"], true);
        assert_eq!(v["windows"], false);
        let mut c = ThemeBuilder::light();
        copy_blur(&b, &mut c);
        assert_eq!(c.frosted, cosmic_theme::BlurStrength::High);
        assert!(c.frosted_panel);
        assert!(!c.palette.is_dark());
    }
    #[test]
    fn set_blur_refuses_bad_values() {
        for bad in [
            json!(1),
            json!({}),
            json!({"strength":14}),
            json!({"panel":1}),
            json!({"other":true}),
            json!({"dark":{"strength":99}}),
            json!({"dark":{},"strength":3}),
        ] {
            assert!(set_blur(&bad).is_err(), "{bad}");
        }
    }
    #[test]
    fn native_fixture() {
        let b: ThemeBuilder = ron::from_str(include_str!("../tests/data/t11.ron")).unwrap();
        let c = colors(&b.build());
        assert_eq!(c["background"], "#1d2433");
        assert_eq!(c["accent"], "#8c9cff");
        assert_eq!(c["mode"], "dark");
    }
}
