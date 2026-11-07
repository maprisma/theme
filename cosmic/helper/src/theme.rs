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
    fn native_fixture() {
        let b: ThemeBuilder = ron::from_str(include_str!("../tests/data/t11.ron")).unwrap();
        let c = colors(&b.build());
        assert_eq!(c["background"], "#24273a");
        assert_eq!(c["accent"], "#b7bdf8");
        assert_eq!(c["mode"], "dark");
    }
}
