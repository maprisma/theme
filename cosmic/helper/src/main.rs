use maprisma_theme_helper::{Result, compositor, terminal, theme};
use serde_json::{Value, json};
use std::path::Path;
fn run(a: &[String]) -> Result<Value> {
    let arg = |i: usize| {
        a.get(i)
            .map(String::as_str)
            .ok_or_else(|| "missing argument".to_string())
    };
    match arg(0)? {
        "apply" => match (arg(1)?, a.len()) {
            ("--colors", 3) => {
                let colors = theme::colors_file(Path::new(arg(2)?))?;
                let mut builder = theme::builder(&colors)?;
                if colors.get("corner").is_none_or(Value::is_null) {
                    builder.corner_radii = theme::current_theme().corner_radii;
                }
                theme::apply(builder)
            }
            ("--ron", 3 | 5) => {
                let mode = if a.len() == 5 {
                    if arg(3)? != "--mode" {
                        return Err("invalid arguments".into());
                    }
                    Some(arg(4)?)
                } else {
                    None
                };
                theme::apply(theme::ron_builder(Path::new(arg(2)?), mode)?)
            }
            _ => Err("usage: apply --colors FILE | --ron FILE [--mode dark|light]".into()),
        },
        "ron-colors" if a.len() == 2 => Ok(theme::colors(
            &theme::ron_builder(Path::new(arg(1)?), None)?.build(),
        )),
        "current" if a.len() == 1 => {
            let t = theme::current_theme();
            Ok(
                json!({"colors":theme::colors(&t),"is_dark":t.is_dark,"corner_radius":t.corner_radii.radius_s[0]}),
            )
        }
        "terminal" if a.len() == 5 && arg(1)? == "--colors" && arg(3)? == "--name" => {
            terminal::write(&theme::colors_file(Path::new(arg(2)?))?, arg(4)?)?;
            Ok(json!({"written":true}))
        }
        "terminal-restore" if a.len() == 1 => {
            terminal::restore()?;
            Ok(json!({"restored":true}))
        }
        "workspaces" | "windows" | "set-tiling" | "move" | "close" | "activate" | "watch" => {
            compositor::run(a)
        }
        _ => Err("invalid command or arguments".into()),
    }
}
fn main() {
    let a: Vec<_> = std::env::args().skip(1).collect();
    if a.first().map(String::as_str) != Some("watch") {
        std::thread::spawn(|| {
            std::thread::sleep(std::time::Duration::from_secs(60));
            println!(
                "{}",
                json!({"error":"timeout","message":"helper exceeded 60 seconds"})
            );
            std::process::exit(1);
        });
    }
    match run(&a) {
        Ok(v) => {
            if !v.is_null() {
                println!("{v}");
            }
        }
        Err(message) => {
            let code = if a
                .first()
                .is_some_and(|s| ["apply", "ron-colors", "terminal"].contains(&s.as_str()))
            {
                "bad_theme"
            } else if message == "not_found" {
                "not_found"
            } else {
                "not_available"
            };
            println!("{}", json!({"error":code,"message":message}));
            std::process::exit(1);
        }
    }
}
