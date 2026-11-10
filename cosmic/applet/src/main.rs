use maprisma_theme_helper::i18n::{current_language, tr, trf};
mod process;
use cosmic::iced::platform_specific::shell::wayland::commands::popup::destroy_popup;
use cosmic::iced::{
    futures::{SinkExt, channel::mpsc},
    stream,
};
use cosmic::{
    Element,
    app::{Core, Task},
    iced::{self, Length, Subscription, mouse, window},
    theme,
    widget::{self, Id, autosize, button, column, icon, mouse_area, text},
};
use maprisma_theme_helper::{
    automation::{Automation, overflow},
    read_bounded,
};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    path::PathBuf,
    process::Stdio,
    sync::LazyLock,
    time::{Duration, Instant},
};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
const APP_ID: &str = "io.github.ubruckhaus.CosmicMaprismaTheme";
const ICON: &str = "io.github.ubruckhaus.CosmicMaprismaTheme-symbolic";
static AUTO: LazyLock<Id> = LazyLock::new(|| Id::new("maprisma-theme-autosize"));
fn main() -> iced::Result {
    cosmic::applet::run::<Applet>(())
}
#[derive(Debug, Clone)]
enum Job {
    Core(Vec<String>),
    Menu,
    Overflow(String, usize),
    Tiling(Automation),
}
#[derive(Debug, Clone)]
enum Message {
    Toggle,
    Popup,
    Scroll(f32),
    Run(Vec<String>),
    Pulse,
    Event(Value),
    WatchError(String),
    Finished(Result<Value, String>, bool),
    Close(window::Id),
}
struct Applet {
    core: Core,
    popup: Option<window::Id>,
    menu: Option<Value>,
    error: Option<String>,
    queue: VecDeque<Job>,
    busy: bool,
    automation: Automation,
    automation_text: Option<String>,
    language: String,
    last_tick: Instant,
    last_tiling: Instant,
    last_scroll: Instant,
    pending_windows: BTreeSet<String>,
}
fn config_path() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        })
        .join("maprisma-theme/automation.json")
}
impl Applet {
    fn enqueue(&mut self, j: Job) {
        // Configuration snapshots and menu refreshes supersede queued older snapshots.
        match &j {
            Job::Tiling(_) => self.queue.retain(|old| !matches!(old, Job::Tiling(_))),
            Job::Menu => {
                if self.queue.iter().any(|old| matches!(old, Job::Menu)) {
                    return;
                }
            }
            Job::Core(args)
                if args
                    .first()
                    .is_some_and(|a| a == "workspace" || a == "tick") =>
            {
                self.queue
                    .retain(|old| !matches!(old, Job::Core(a) if a.first() == args.first()));
            }
            _ => {}
        }
        if self.queue.len() < 64 {
            self.queue.push_back(j);
        } else {
            self.error = Some(tr("Too many pending actions").into());
        }
    }
    fn next(&mut self) -> Task<Message> {
        if self.busy {
            return Task::none();
        }
        let Some(job) = self.queue.pop_front() else {
            return Task::none();
        };
        self.busy = true;
        let menu = matches!(job, Job::Menu);
        Task::perform(execute(job), move |v| {
            cosmic::Action::App(Message::Finished(v, menu))
        })
    }
    fn reload(&mut self) {
        let language = current_language();
        if self.language != language {
            self.language = language;
            if self.popup.is_some() {
                self.enqueue(Job::Menu);
            }
        }
        match read_bounded(&config_path()) {
            Ok(s) if self.automation_text.as_ref() != Some(&s) => {
                match serde_json::from_str::<Automation>(&s) {
                    Ok(a) => {
                        self.automation_text = Some(s);
                        self.automation = a.clone();
                        if a.tiling.active {
                            self.enqueue(Job::Tiling(a));
                        }
                    }
                    Err(e) => self.error = Some(trf("Automation settings: {0}", &[e.to_string()])),
                }
            }
            Err(_) if !config_path().exists() => {
                self.automation = Automation::default();
                self.automation_text = None;
            }
            Err(e) => self.error = Some(trf("Automation settings: {0}", &[e.to_string()])),
            _ => {}
        }
    }
}
impl cosmic::Application for Applet {
    type Executor = cosmic::SingleThreadExecutor;
    type Flags = ();
    type Message = Message;
    const APP_ID: &'static str = APP_ID;
    fn core(&self) -> &Core {
        &self.core
    }
    fn core_mut(&mut self) -> &mut Core {
        &mut self.core
    }
    fn init(core: Core, _: ()) -> (Self, Task<Message>) {
        let now = Instant::now();
        let mut app = Self {
            core,
            popup: None,
            menu: None,
            error: None,
            queue: VecDeque::new(),
            busy: false,
            automation: Automation::default(),
            automation_text: None,
            language: current_language(),
            last_tick: now,
            last_tiling: now,
            last_scroll: now - Duration::from_secs(1),
            pending_windows: BTreeSet::new(),
        };
        app.reload();
        // Consume the session even when disabled, so enabling later waits for login.
        if startup_autostart(app.automation.autostart, claim_autostart) {
            app.enqueue(Job::Core(vec!["autostart".into()]));
        }
        let task = app.next();
        (app, task)
    }
    fn subscription(&self) -> Subscription<Message> {
        Subscription::batch(vec![
            iced::time::every(Duration::from_secs(1)).map(|_| Message::Pulse),
            Subscription::run_with("maprisma-watch", |_| {
                stream::channel(32, |mut out| async move {
                    watch(&mut out).await;
                })
            }),
        ])
    }
    fn on_close_requested(&self, id: window::Id) -> Option<Message> {
        Some(Message::Close(id))
    }
    fn update(&mut self, m: Message) -> Task<Message> {
        match m {
            Message::Toggle => {
                if let Err(e) = process::toggle() {
                    self.error = Some(e);
                }
            }
            Message::Popup => {
                if let Some(id) = self.popup.take() {
                    return destroy_popup(id);
                }
                self.menu = None;
                self.error = None;
                self.enqueue(Job::Menu);
                let start = self.next();
                return Task::batch([
                    start,
                    cosmic::surface::surface_task(cosmic::surface::action::app_popup(
                        |_| Default::default(),
                        |app: &mut Self| {
                            let id = window::Id::unique();
                            app.popup = Some(id);
                            let mut s = app.core.applet.get_popup_settings(
                                app.core.main_window_id().unwrap(),
                                id,
                                None,
                                None,
                                None,
                            );
                            s.positioner.size = Some((340, 480));
                            s
                        },
                        None,
                    )),
                ]);
            }
            Message::Close(id) => {
                if self.popup == Some(id) {
                    self.popup = None;
                }
            }
            Message::Scroll(y) => {
                if y != 0. && self.last_scroll.elapsed() >= Duration::from_millis(300) {
                    self.last_scroll = Instant::now();
                    self.enqueue(Job::Core(vec![
                        "bg".into(),
                        if y > 0. { "prev" } else { "next" }.into(),
                    ]));
                }
            }
            Message::Run(args) => {
                self.enqueue(Job::Core(args));
            }
            Message::Pulse => {
                self.reload();
                if self.automation.tiling.active
                    && self.last_tiling.elapsed() >= Duration::from_secs(15)
                {
                    self.last_tiling = Instant::now();
                    self.enqueue(Job::Tiling(self.automation.clone()));
                }
                if self.automation.tick && self.last_tick.elapsed() >= Duration::from_secs(60) {
                    self.last_tick = Instant::now();
                    self.enqueue(Job::Core(vec!["tick".into()]));
                }
            }
            Message::Event(v) => {
                if matches!(v["event"].as_str(), Some("window_moved" | "window_closed")) {
                    if let Some(id) = v["id"].as_str() {
                        self.queue
                            .retain(|j| !matches!(j, Job::Overflow(queued, _) if queued == id));
                    }
                }
                if let Some((id, workspace)) =
                    overflow_event(&mut self.pending_windows, &v, self.automation.tiling.active)
                {
                    self.enqueue(Job::Overflow(id, workspace));
                }
                if v["event"] == "workspace" && self.automation.workspace_events {
                    if let Some(i) = v["index"].as_u64() {
                        self.enqueue(Job::Core(vec!["workspace".into(), i.to_string()]));
                    }
                }
            }
            Message::WatchError(e) => {
                self.error = Some(e);
            }
            Message::Finished(v, is_menu) => {
                self.busy = false;
                match v {
                    Ok(v) => {
                        if is_menu {
                            self.menu = Some(v);
                        } else if self.popup.is_some() {
                            self.enqueue(Job::Menu);
                        }
                    }
                    Err(e) => {
                        self.error = Some(e);
                    }
                }
            }
        }
        self.next()
    }
    fn view(&self) -> Element<'_, Message> {
        let size = self.core.applet.suggested_size(true).0;
        let padding = self.core.applet.suggested_padding(true).0;
        let button = button::custom(icon::from_name(ICON).size(size).icon())
            .padding(padding)
            .on_press_down(Message::Toggle)
            .class(theme::Button::AppletIcon);
        let content = mouse_area(button)
            .on_right_press(Message::Popup)
            .on_scroll(|d| {
                Message::Scroll(match d {
                    mouse::ScrollDelta::Lines { y, .. } | mouse::ScrollDelta::Pixels { y, .. } => y,
                })
            });
        let tooltip = widget::tooltip(
            content,
            text::body(tr("Maprisma Theme · scroll: wallpaper · right-click: favorites")),
            widget::tooltip::Position::Bottom,
        );
        autosize::autosize(tooltip, AUTO.clone()).into()
    }
    fn view_window(&self, _: window::Id) -> Element<'_, Message> {
        let mut rows = column::with_children(vec![])
            .spacing(6)
            .padding(12)
            .width(Length::Fixed(340.));
        if let Some(e) = &self.error {
            rows = rows.push(text::body(e));
        }
        if let Some(menu) = &self.menu {
            rows = rows.push(text::heading(
                menu["title"].as_str().map(str::to_owned).unwrap_or_else(|| tr("Favorite themes")),
            ));
            if let Some(themes) = menu["themes"].as_array() {
                if themes.is_empty() {
                    rows = rows.push(text::body(
                        menu["empty_note"]
                            .as_str()
                            .map(str::to_owned).unwrap_or_else(|| tr("No favorite themes yet")),
                    ));
                }
                for t in themes {
                    if let (Some(slug), Some(name)) = (t["slug"].as_str(), t["name"].as_str()) {
                        let label = if t["current"] == true {
                            format!("✓ {name}")
                        } else {
                            name.to_owned()
                        };
                        rows = rows.push(
                            button::text(label)
                                .on_press(Message::Run(vec!["apply".into(), slug.into()])),
                        );
                    }
                }
            }
            if let Some(items) = menu["items"].as_array() {
                for i in items {
                    let label = i["label"].as_str().unwrap_or("");
                    match i["id"].as_str() {
                        Some("open") => {
                            rows = rows.push(button::text(label).on_press(Message::Toggle))
                        }
                        Some("next_wallpaper") => {
                            rows = rows.push(
                                button::text(label)
                                    .on_press(Message::Run(vec!["bg".into(), "next".into()])),
                            )
                        }
                        _ => {}
                    }
                }
            }
        } else {
            rows = rows.push(text::body(if self.busy {
                tr("Loading themes…")
            } else {
                tr("Themes unavailable")
            }));
            rows = rows.push(button::text(tr("Open Maprisma Theme")).on_press(Message::Toggle));
        }
        self.core
            .applet
            .popup_container(widget::scrollable(rows).height(Length::Shrink))
            .into()
    }
    fn style(&self) -> Option<iced::theme::Style> {
        Some(cosmic::applet::style())
    }
}
fn claim_autostart() -> bool {
    let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") else {
        return false;
    };
    let dir = PathBuf::from(runtime).join("maprisma-theme");
    if std::fs::create_dir_all(&dir).is_err() {
        return false;
    } // Runtime directories are cleared at logout. Include session ID for concurrent sessions.
    let session = std::env::var("XDG_SESSION_ID")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
                .ok()
                .and_then(|boot| {
                    Some(format!("{}-{}", boot.trim(), {
                        use std::os::unix::fs::MetadataExt;
                        std::fs::metadata("/proc/self").ok()?.uid()
                    }))
                })
        });
    let Some(session) = session else {
        return false;
    };
    let safe: String = session
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect();
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dir.join(format!("autostart-{safe}")))
        .is_ok()
}
async fn execute(job: Job) -> Result<Value, String> {
    let helper =
        |args: Vec<String>| async move { process::call("maprisma-theme-helper", &args).await };
    match job {
        Job::Menu => process::call("maprisma-theme-core", &["menu".into()]).await,
        Job::Core(a) => process::call("maprisma-theme-core", &a).await,
        Job::Tiling(a) => {
            let ws = helper(vec!["workspaces".into()]).await?;
            if let Some(w) = ws["workspaces"].as_array() {
                for w in w {
                    let Some(i) = w["index"].as_u64().map(|i| i as usize) else {
                        continue;
                    };
                    let mode = if a.tiling.floating.contains(&i) {
                        Some(false)
                    } else if a.tiling.tiled.contains(&i) {
                        Some(true)
                    } else {
                        None
                    };
                    if let Some(mode) = mode {
                        if w["tiling"] != mode {
                            helper(vec![
                                "set-tiling".into(),
                                i.to_string(),
                                if mode { "on" } else { "off" }.into(),
                            ])
                            .await?;
                        }
                    }
                }
            }
            Ok(Value::Null)
        }
        Job::Overflow(id, source) => {
            let a: Automation =
                serde_json::from_str(&read_bounded(&config_path())?).map_err(|e| e.to_string())?;
            if !a.tiling.active {
                return Ok(Value::Null);
            }
            let ws = helper(vec!["workspaces".into()]).await?;
            let windows = helper(vec!["windows".into()]).await?;
            let mut counts = BTreeMap::new();
            for w in ws["workspaces"]
                .as_array()
                .ok_or(tr("invalid workspaces response"))?
            {
                if let Some(i) = w["index"].as_u64() {
                    counts.insert(i as usize, 0);
                }
            }
            let windows = windows["windows"]
                .as_array()
                .ok_or(tr("invalid windows response"))?;
            if !windows
                .iter()
                .any(|w| w["id"] == id && w["workspace"].as_u64() == Some(source as u64))
            {
                return Ok(Value::Null);
            }
            for w in windows {
                if let Some(i) = w["workspace"].as_u64() {
                    if let Some(n) = counts.get_mut(&(i as usize)) {
                        *n += 1;
                    }
                }
            }
            if let Some(dest) = overflow(source, &counts, &a.tiling) {
                helper(vec!["move".into(), id, dest.to_string()]).await?;
            }
            Ok(Value::Null)
        }
    }
}
async fn watch(out: &mut mpsc::Sender<Message>) {
    loop {
        let child = tokio::process::Command::new(process::binary("maprisma-theme-helper"))
            .arg("watch")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn();
        match child {
            Ok(mut child) => {
                if let Some(stdout) = child.stdout.take() {
                    let mut reader = BufReader::new(stdout);
                    loop {
                        let mut line = String::new();
                        match (&mut reader)
                            .take(1024 * 1024 + 1)
                            .read_line(&mut line)
                            .await
                        {
                            Ok(n) if n > 0 && n <= 1024 * 1024 => {
                                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                                    let message = if v.get("error").is_some() {
                                        Message::WatchError(trf(
                                            "Compositor connection: {0}",
                                            &[v["message"].as_str().map(str::to_owned).unwrap_or_else(|| tr("helper error"))]
                                        ))
                                    } else {
                                        Message::Event(v)
                                    };
                                    if out.send(message).await.is_err() {
                                        return;
                                    }
                                }
                            }
                            _ => break,
                        }
                    }
                }
                let _ = child.kill().await;
                if out
                    .send(Message::WatchError(
                        tr("Compositor connection closed; retrying…").into(),
                    ))
                    .await
                    .is_err()
                {
                    return;
                }
            }
            Err(e) => {
                if out
                    .send(Message::WatchError(trf("Compositor connection: {0}", &[e.to_string()])))
                    .await
                    .is_err()
                {
                    return;
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

// Called only at initialization; always consume the marker, including disabled sessions.
fn startup_autostart(enabled: bool, claim: impl FnOnce() -> bool) -> bool {
    claim() && enabled
}
fn overflow_event(
    pending: &mut BTreeSet<String>,
    v: &Value,
    active: bool,
) -> Option<(String, usize)> {
    let id = v["id"].as_str()?;
    match v["event"].as_str()? {
        "window_closed" => {
            pending.remove(id);
        }
        "window_new" if active => {
            if let Some(i) = v["workspace"].as_u64() {
                return Some((id.into(), i as usize));
            }
            pending.insert(id.into());
        }
        "window_moved" => {
            if let Some(i) = v["workspace"].as_u64() {
                if pending.remove(id) && active {
                    return Some((id.into(), i as usize));
                }
            }
        }
        _ => {}
    }
    None
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn disabled_start_consumes_session() {
        let mut claimed = false;
        assert!(!startup_autostart(false, || {
            claimed = true;
            true
        }));
        assert!(claimed);
        assert!(!startup_autostart(true, || false));
        assert!(startup_autostart(true, || true));
    }
    #[test]
    fn overflow_waits_for_first_workspace_only() {
        let mut pending = BTreeSet::new();
        assert_eq!(
            overflow_event(
                &mut pending,
                &json!({"event":"window_new","id":"a","workspace":null}),
                true
            ),
            None
        );
        assert_eq!(
            overflow_event(
                &mut pending,
                &json!({"event":"window_moved","id":"a","workspace":null}),
                true
            ),
            None
        );
        let moved = json!({"event":"window_moved","id":"a","workspace":2});
        assert_eq!(
            overflow_event(&mut pending, &moved, true),
            Some(("a".into(), 2))
        );
        assert_eq!(overflow_event(&mut pending, &moved, true), None);
        overflow_event(&mut pending, &json!({"event":"window_new","id":"a"}), true);
        overflow_event(
            &mut pending,
            &json!({"event":"window_closed","id":"a"}),
            true,
        );
        assert!(pending.is_empty());
        assert_eq!(
            overflow_event(
                &mut pending,
                &json!({"event":"window_new","id":"b","workspace":1}),
                true
            ),
            Some(("b".into(), 1))
        );
    }
}
