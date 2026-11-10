use maprisma_theme_helper::i18n::{tr, trf};
use serde_json::Value;
use std::{path::PathBuf, process::Stdio, time::Duration};
use tokio::{io::AsyncReadExt, process::Command};
pub fn binary(name: &str) -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let p = dir.join(name);
            if p.is_file() {
                return p;
            }
        }
    }
    let local = PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
        .join(".local/bin")
        .join(name);
    if local.is_file() {
        local
    } else {
        PathBuf::from(name)
    }
}
pub async fn call(name: &str, args: &[String]) -> Result<Value, String> {
    let mut child = Command::new(binary(name))
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("{name}: {e}"))?;
    let stdout = child.stdout.take().ok_or(tr("missing stdout"))?;
    let result = tokio::time::timeout(Duration::from_secs(60), async {
        let mut bytes = Vec::new();
        stdout
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|e| e.to_string())?;
        if bytes.len() > 1024 * 1024 {
            return Err(tr("response exceeds 1 MiB").into());
        }
        let status = child.wait().await.map_err(|e| e.to_string())?;
        let v: Value =
            serde_json::from_slice(&bytes).map_err(|e| trf("{0}: invalid JSON: {1}", &[name.to_string(), e.to_string()]))?;
        if !status.success() || v.get("error").is_some() {
            return Err(v["message"].as_str().map(str::to_owned).unwrap_or_else(|| tr("command failed")).to_owned());
        }
        Ok(v)
    })
    .await;
    match result {
        Ok(v) => v,
        Err(_) => {
            let _ = child.kill().await;
            Err(trf("{0}: timed out after 60 seconds", &[name.to_string()]))
        }
    }
}
pub fn toggle() -> Result<(), String> {
    let mut child = std::process::Command::new(binary("maprisma-theme"))
        .arg("--toggle")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn argv_json_and_failed_response() {
        // The quote characters and spaces reach echo literally; no shell interprets them.
        let args = vec![r#"{"text":"a $HOME; `literal`"}"#.to_owned()];
        assert_eq!(
            call("/usr/bin/echo", &args).await.unwrap()["text"],
            "a $HOME; `literal`"
        );
        let bad = call("/usr/bin/python3", &["-c".into(), "import sys; print('{\"error\":\"bad\",\"message\":\"expected failure\"}'); sys.exit(1)".into()]).await;
        assert_eq!(bad.unwrap_err(), "expected failure");
    }
    #[tokio::test]
    async fn excessive_stdout_is_rejected() {
        let result = call(
            "/usr/bin/python3",
            &["-c".into(), "print('x' * (1024 * 1024 + 1))".into()],
        )
        .await;
        assert_eq!(result.unwrap_err(), tr("response exceeds 1 MiB"));
    }
}
