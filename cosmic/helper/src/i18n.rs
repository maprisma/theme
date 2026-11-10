//! Bundled gettext catalogs, shared by the helper and panel applet.
use serde_json::Value;
use std::{collections::BTreeMap, io::Read, sync::OnceLock};

pub fn system_language(environment: &BTreeMap<String, String>) -> String {
    for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        if let Some(value) = environment.get(name).filter(|v| !v.is_empty()) {
            let lower = value.to_lowercase();
            let code = lower.split(['_', '-', '.', '@']).next().unwrap_or("en");
            return if ["en", "de", "fr", "es", "it", "pt", "nl", "pl"].contains(&code) {
                code.to_owned()
            } else {
                "en".to_owned()
            };
        }
    }
    "en".to_owned()
}

pub fn current_language() -> String {
    let environment: BTreeMap<_, _> = std::env::vars().collect();
    let config = environment.get("XDG_CONFIG_HOME").filter(|p| p.starts_with('/'))
        .cloned().unwrap_or_else(|| format!("{}/.config", environment.get("HOME").map(String::as_str).unwrap_or("/nonexistent")));
    let mut contents = String::new();
    if let Ok(file) = std::fs::File::open(format!("{config}/maprisma-theme/settings.json")) {
        if file.take(65537).read_to_string(&mut contents).is_ok() && contents.len() <= 65536 {
            if let Ok(value) = serde_json::from_str::<Value>(&contents) {
                if let Some(code) = value["language"].as_str() {
                    if ["en", "de", "fr", "es", "it", "pt", "nl", "pl"].contains(&code) {
                        return code.to_owned();
                    }
                }
            }
        }
    }
    system_language(&environment)
}

pub fn tr(english: &str) -> String {
    static CATALOGS: OnceLock<BTreeMap<&str, BTreeMap<String, String>>> = OnceLock::new();
    let catalogs = CATALOGS.get_or_init(|| {
        let mut out = BTreeMap::new();
        for (code, base, extra) in [
            ("de", include_str!("../../../translations/de.json"), include_str!("../../../translations/extra/de.json")),
            ("fr", include_str!("../../../translations/fr.json"), include_str!("../../../translations/extra/fr.json")),
            ("es", include_str!("../../../translations/es.json"), include_str!("../../../translations/extra/es.json")),
            ("it", include_str!("../../../translations/it.json"), include_str!("../../../translations/extra/it.json")),
            ("pt", include_str!("../../../translations/pt.json"), include_str!("../../../translations/extra/pt.json")),
            ("nl", include_str!("../../../translations/nl.json"), include_str!("../../../translations/extra/nl.json")),
            ("pl", include_str!("../../../translations/pl.json"), include_str!("../../../translations/extra/pl.json")),
        ] {
            let mut strings = BTreeMap::new();
            for json in [base, extra] {
                let value: Value = serde_json::from_str(json).expect("checked-in translation catalog");
                for (key, text) in value.as_object().expect("catalog object") {
                    if let Some(text) = text.as_str() { strings.insert(key.clone(), text.to_owned()); }
                }
            }
            out.insert(code, strings);
        }
        out
    });
    catalogs.get(current_language().as_str()).and_then(|c| c.get(english))
        .cloned().unwrap_or_else(|| english.to_owned())
}

pub fn trf(english: &str, values: &[String]) -> String {
    // Replace placeholders in one pass: braces in data are never interpreted.
    let translated = tr(english);
    let mut out = String::new();
    let mut rest = translated.as_str();
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        rest = &rest[start..];
        if let Some(end) = rest.find('}') {
            if let Ok(index) = rest[1..end].parse::<usize>() {
                if let Some(value) = values.get(index) {
                    out.push_str(value);
                    rest = &rest[end + 1..];
                    continue;
                }
            }
        }
        out.push('{');
        rest = &rest[1..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn locale_priority_and_fallback() {
        let env = |a: &str, b: &str, c: &str| BTreeMap::from([
            ("LC_ALL".into(), a.into()), ("LC_MESSAGES".into(), b.into()), ("LANG".into(), c.into()),
        ]);
        assert_eq!(system_language(&env("de_DE.UTF-8", "fr", "pl")), "de");
        assert_eq!(system_language(&env("", "fr-FR", "pl")), "fr");
        assert_eq!(system_language(&env("", "", "pl_PL@x")), "pl");
        assert_eq!(system_language(&env("xx_YY", "de", "pl")), "en");
        assert_eq!(system_language(&env("C", "de", "pl")), "en");
        assert_eq!(system_language(&env("", "", "")), "en");
    }
}
