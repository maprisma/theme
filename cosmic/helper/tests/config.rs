use serde_json::{Value, json};
use std::{fs, process::Command};
fn temp() -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!(
        "maprisma-test-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&p).unwrap();
    p
}
fn run(root: &std::path::Path, args: &[&str]) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_maprisma-theme-helper"))
        .env("XDG_CONFIG_HOME", root)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}
#[test]
fn terminal_scheme_temp_config() {
    let root = temp();
    let colors = root.join("colors.json");
    fs::write(
        &colors,
        json!({"mode":"dark","background":"#112233","foreground":"#aabbcc","red":"#ff0000"})
            .to_string(),
    )
    .unwrap();
    let dir = root.join("cosmic/com.system76.CosmicTerm/v1");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("color_schemes_dark"),
        r##"{7:(name:"User",foreground:"#ffffff")}"##,
    )
    .unwrap();
    run(
        &root,
        &[
            "terminal",
            "--colors",
            colors.to_str().unwrap(),
            "--name",
            "Test",
        ],
    );
    let text = fs::read_to_string(dir.join("color_schemes_dark")).unwrap();
    assert!(text.contains("Maprisma: Test"));
    assert!(text.contains("User"));
    assert!(!text.contains("Some("));
    let parsed: std::collections::BTreeMap<u64, maprisma_theme_helper::terminal::Scheme> =
        ron::from_str(&text).unwrap();
    assert_eq!(parsed[&8].background.as_deref(), Some("#112233"));
    assert_eq!(
        fs::read_to_string(dir.join("syntax_theme_dark")).unwrap(),
        "\"Maprisma: Test\""
    );
    run(
        &root,
        &[
            "terminal",
            "--colors",
            colors.to_str().unwrap(),
            "--name",
            "Again",
        ],
    );
    let text = fs::read_to_string(dir.join("color_schemes_dark")).unwrap();
    assert!(!text.contains("Maprisma: Test"));
    assert!(text.contains("Again"));
    let dark_schemes = text;
    fs::write(
        &colors,
        json!({"mode":"light","background":"#ffffff","foreground":"#112233"}).to_string(),
    )
    .unwrap();
    run(
        &root,
        &[
            "terminal",
            "--colors",
            colors.to_str().unwrap(),
            "--name",
            "Day",
        ],
    );
    assert_eq!(
        fs::read_to_string(dir.join("color_schemes_dark")).unwrap(),
        dark_schemes
    );
    assert_eq!(
        fs::read_to_string(dir.join("syntax_theme_light")).unwrap(),
        "\"Maprisma: Day\""
    );
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn apply_writes_builder_theme_and_mode() {
    let root = temp();
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/t11.ron");
    run(
        &root,
        &[
            "apply",
            "--ron",
            fixture.to_str().unwrap(),
            "--mode",
            "light",
        ],
    );
    let cosmic = root.join("cosmic");
    assert!(
        cosmic
            .join("com.system76.CosmicTheme.Light.Builder/v2/palette")
            .is_file()
    );
    assert!(
        cosmic
            .join("com.system76.CosmicTheme.Light/v2/palette")
            .is_file()
    );
    assert_eq!(
        fs::read_to_string(cosmic.join("com.system76.CosmicTheme.Mode/v1/is_dark")).unwrap(),
        "false"
    );
    assert_eq!(run(&root, &["current"])["is_dark"], false);
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn oversized_rejected() {
    let root = temp();
    let f = root.join("large.ron");
    fs::write(&f, vec![b' '; 1024 * 1024 + 1]).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_maprisma-theme-helper"))
        .env("XDG_CONFIG_HOME", &root)
        .args(["ron-colors", f.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["error"],
        "bad_theme"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn null_corners_preserve_current_radii_across_mode_switch() {
    let root = temp();
    let colors = root.join("colors.json");
    fs::write(
        &colors,
        json!({"mode":"dark","corner":"square"}).to_string(),
    )
    .unwrap();
    run(&root, &["apply", "--colors", colors.to_str().unwrap()]);
    assert_eq!(run(&root, &["current"])["corner_radius"], 2.0);
    fs::write(&colors, json!({"mode":"light","corner":null}).to_string()).unwrap();
    run(&root, &["apply", "--colors", colors.to_str().unwrap()]);
    let current = run(&root, &["current"]);
    assert_eq!(current["corner_radius"], 2.0);
    assert_eq!(current["is_dark"], false);
    fs::remove_dir_all(root).unwrap();
}
