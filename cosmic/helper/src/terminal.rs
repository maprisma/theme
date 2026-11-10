//! Wire schema verified against cosmic-term src/config.rs and installed 1.11 strings.
//! Hex colors serialize as strings, not RON Some(...); scheme IDs are transparent u64.
use crate::i18n::tr;
use crate::{Result, read_bounded, theme};
use cosmic_config::{Config, ConfigSet};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, path::Path};
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Ansi {
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub black: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub red: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub green: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub yellow: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub blue: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub magenta: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub cyan: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub white: Option<String>,
}
fn de_color<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Option<String>, D::Error> {
    String::deserialize(d).map(Some)
}
fn ser_color<S: serde::Serializer>(
    v: &Option<String>,
    s: S,
) -> std::result::Result<S::Ok, S::Error> {
    v.as_ref().unwrap().serialize(s)
}
// Custom serde below accepts the terminal's bare hex strings for optional fields.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Scheme {
    pub name: String,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub foreground: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub background: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub cursor: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub bright_foreground: Option<String>,
    #[serde(
        default,
        deserialize_with = "de_color",
        serialize_with = "ser_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub dim_foreground: Option<String>,
    pub normal: Ansi,
    pub bright: Ansi,
    pub dim: Ansi,
}
fn ansi(v: &Value, prefix: &str) -> Ansi {
    let c = |n: &str| {
        v.get(format!("{prefix}{n}"))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    Ansi {
        black: c("black"),
        red: c("red"),
        green: c("green"),
        yellow: c("yellow"),
        blue: c("blue"),
        magenta: c("magenta"),
        cyan: c("cyan"),
        white: c("white"),
    }
}
pub fn write(v: &Value, name: &str) -> Result<()> {
    let config = Config::new("com.system76.CosmicTerm", 1).map_err(|e| e.to_string())?;
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        });
    write_at(
        v,
        name,
        &config,
        &root.join("cosmic/com.system76.CosmicTerm/v1"),
    )
}
pub fn write_at(v: &Value, name: &str, config: &Config, dir: &Path) -> Result<()> {
    if name.is_empty() || name.len() > 256 {
        return Err(tr("invalid scheme name").into());
    }
    let dark = theme::dark(v)?;
    let key = if dark {
        "color_schemes_dark"
    } else {
        "color_schemes_light"
    };
    let path = dir.join(key);
    let options = ron::Options::default()
        .with_default_extension(ron::extensions::Extensions::IMPLICIT_SOME)
        .with_default_extension(ron::extensions::Extensions::UNWRAP_NEWTYPES);
    let mut schemes: BTreeMap<u64, Scheme> = if path.exists() {
        options
            .from_str(&read_bounded(&path)?)
            .map_err(|e| e.to_string())?
    } else {
        BTreeMap::new()
    };
    // One owned scheme per mode, preserving every non-Maprisma scheme and its ID.
    let id = if let Some((id, _)) = schemes
        .iter()
        .find(|(_, s)| s.name.starts_with("Maprisma: "))
    {
        *id
    } else {
        schemes
            .keys()
            .next_back()
            .copied()
            .unwrap_or(0)
            .checked_add(1)
            .ok_or(tr("scheme IDs exhausted"))?
    };
    schemes.retain(|_, s| !s.name.starts_with("Maprisma: "));
    let get = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
    let name = format!("Maprisma: {name}");
    schemes.insert(
        id,
        Scheme {
            name: name.clone(),
            foreground: get("foreground"),
            background: get("background"),
            cursor: get("cursor"),
            normal: ansi(v, ""),
            bright: ansi(v, "bright_"),
            ..Default::default()
        },
    );
    remember(dir)?;
    config.set(key, schemes).map_err(|e| e.to_string())?;
    config
        .set(
            if dark {
                "syntax_theme_dark"
            } else {
                "syntax_theme_light"
            },
            name,
        )
        .map_err(|e| e.to_string())
}

fn config_dir() -> std::path::PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        })
        .join("cosmic/com.system76.CosmicTerm/v1")
}
fn previous_path() -> std::path::PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".local/state")
        })
        .join("maprisma-theme/terminal-previous.json")
}
const SELECTIONS: [&str; 2] = ["syntax_theme_dark", "syntax_theme_light"];
fn remember(dir: &Path) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let path = previous_path();
    if path.exists() {
        return Ok(());
    }
    let mut previous = BTreeMap::<String, Option<String>>::new();
    for key in SELECTIONS {
        let p = dir.join(key);
        previous.insert(
            key.into(),
            if p.exists() {
                Some(ron::from_str::<String>(&read_bounded(&p)?).map_err(|e| e.to_string())?)
            } else {
                None
            },
        );
    }
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
    {
        Ok(mut file) => {
            if let Err(e) =
                file.write_all(&serde_json::to_vec(&previous).map_err(|e| e.to_string())?)
            {
                let _ = std::fs::remove_file(&path);
                return Err(e.to_string());
            }
            Ok(())
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
pub fn restore() -> Result<()> {
    let path = previous_path();
    if !path.exists() {
        return Ok(());
    }
    let previous: BTreeMap<String, Option<String>> =
        serde_json::from_str(&read_bounded(&path)?).map_err(|e| e.to_string())?;
    let config = Config::new("com.system76.CosmicTerm", 1).map_err(|e| e.to_string())?;
    let dir = config_dir();
    for key in SELECTIONS {
        match previous.get(key).ok_or(tr("incomplete terminal backup"))? {
            Some(name) => config.set(key, name).map_err(|e| e.to_string())?,
            None => {
                if dir.join(key).exists() {
                    std::fs::remove_file(dir.join(key)).map_err(|e| e.to_string())?;
                }
            }
        }
    }
    for key in ["color_schemes_dark", "color_schemes_light"] {
        let p = dir.join(key);
        if !p.exists() {
            continue;
        }
        let options = ron::Options::default()
            .with_default_extension(ron::extensions::Extensions::IMPLICIT_SOME)
            .with_default_extension(ron::extensions::Extensions::UNWRAP_NEWTYPES);
        let mut schemes: BTreeMap<u64, Scheme> = options
            .from_str(&read_bounded(&p)?)
            .map_err(|e| e.to_string())?;
        schemes.retain(|_, s| !s.name.starts_with("Maprisma: "));
        config.set(key, schemes).map_err(|e| e.to_string())?;
    }
    std::fs::remove_file(path).map_err(|e| e.to_string())
}
