use crate::i18n::tr;
use crate::Result;
use cosmic_client_toolkit::cosmic_protocols::{
    toplevel_info::v1::client::zcosmic_toplevel_handle_v1::State as TopState,
    toplevel_management::v1::client::zcosmic_toplevel_manager_v1 as manager,
    workspace::v2::client::zcosmic_workspace_handle_v2::{TilingState, WorkspaceCapabilities},
};
use cosmic_client_toolkit::{
    GlobalData,
    toplevel_info::{ToplevelInfoHandler, ToplevelInfoState},
    toplevel_management::ToplevelManagerState,
    workspace::{Workspace, WorkspaceHandler, WorkspaceState},
};
use sctk::{
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    seat::{Capability, SeatHandler, SeatState},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    os::fd::{AsFd, AsRawFd},
    time::{Duration, Instant},
};
use wayland_client::{
    Connection, Dispatch, Proxy, QueueHandle, WEnum,
    globals::registry_queue_init,
    protocol::{wl_output::WlOutput, wl_seat::WlSeat},
};
use wayland_protocols::ext::{
    foreign_toplevel_list::v1::client::ext_foreign_toplevel_handle_v1::ExtForeignToplevelHandleV1,
    workspace::v1::client::ext_workspace_handle_v1::State as WsState,
};
struct State {
    registry: RegistryState,
    outputs: OutputState,
    seats: SeatState,
    ws: WorkspaceState,
    tops: ToplevelInfoState,
    manager: Option<ToplevelManagerState>,
    info_ready: bool,
    caps: Vec<WEnum<manager::ZcosmicToplelevelManagementCapabilitiesV1>>,
}
impl ProvidesRegistryState for State {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    sctk::registry_handlers!(OutputState, SeatState);
}
impl OutputHandler for State {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.outputs
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlOutput) {}
}
impl SeatHandler for State {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seats
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat) {}
    fn new_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat, _: Capability) {}
    fn remove_capability(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: WlSeat,
        _: Capability,
    ) {
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat) {}
}
impl WorkspaceHandler for State {
    fn workspace_state(&mut self) -> &mut WorkspaceState {
        &mut self.ws
    }
    fn done(&mut self) {}
}
impl ToplevelInfoHandler for State {
    fn toplevel_info_state(&mut self) -> &mut ToplevelInfoState {
        &mut self.tops
    }
    fn new_toplevel(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ExtForeignToplevelHandleV1,
    ) {
    }
    fn update_toplevel(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ExtForeignToplevelHandleV1,
    ) {
    }
    fn toplevel_closed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ExtForeignToplevelHandleV1,
    ) {
    }
    fn info_done(&mut self, _: &Connection, _: &QueueHandle<Self>) {
        self.info_ready = true;
    }
}
impl Dispatch<manager::ZcosmicToplevelManagerV1, GlobalData> for State {
    fn event(
        s: &mut Self,
        _: &manager::ZcosmicToplevelManagerV1,
        e: manager::Event,
        _: &GlobalData,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let manager::Event::Capabilities { capabilities } = e {
            s.caps = capabilities
                .chunks_exact(4)
                .map(|c| WEnum::from(u32::from_ne_bytes(c.try_into().unwrap())))
                .collect();
        }
    }
}
sctk::delegate_output!(State);
sctk::delegate_registry!(State);
sctk::delegate_seat!(State);
cosmic_client_toolkit::delegate_workspace!(State);
cosmic_client_toolkit::delegate_toplevel_info!(State);
impl State {
    fn output_name(&self, o: &WlOutput) -> String {
        self.outputs
            .info(o)
            .and_then(|i| i.name)
            .unwrap_or_default()
    }
    fn output(&self) -> Option<WlOutput> {
        self.tops
            .toplevels()
            .find(|t| t.state.contains(&TopState::Activated))
            .and_then(|t| t.output.iter().min_by_key(|o| self.output_name(o)).cloned())
            .or_else(|| self.outputs.outputs().min_by_key(|o| self.output_name(o)))
    }
    fn ordered(&self) -> Vec<&Workspace> {
        let output = self.output();
        let group = self
            .ws
            .workspace_groups()
            .find(|g| output.as_ref().is_some_and(|o| g.outputs.contains(o)));
        let mut w: Vec<_> = self
            .ws
            .workspaces()
            .filter(|w| {
                group
                    .as_ref()
                    .is_some_and(|g| g.workspaces.contains(&w.handle))
            })
            .collect();
        w.sort_by(|a, b| a.coordinates.cmp(&b.coordinates).then(a.name.cmp(&b.name)));
        w
    }
    fn workspace_json(&self) -> Value {
        let output = self
            .output()
            .map(|o| self.output_name(&o))
            .unwrap_or_default();
        let w = self.ordered();
        json!({"can_tile":w.iter().any(|w|w.cosmic_capabilities.contains(WorkspaceCapabilities::SetTilingState)),"workspaces":w.iter().enumerate().map(|(i,w)|json!({"index":i+1,"name":w.name,"active":w.state.contains(WsState::Active),"tiling":matches!(w.tiling,Some(WEnum::Value(TilingState::TilingEnabled))),"output":output})).collect::<Vec<_>>()})
    }
    fn window_json(&self) -> Value {
        let ordered = self.ordered();
        json!({"windows":self.tops.toplevels().map(|t|json!({"id":t.identifier,"app_id":t.app_id,"title":t.title,"workspace":ordered.iter().position(|w|t.workspace.contains(&w.handle)).map(|i|i+1),"output":t.output.iter().map(|o|self.output_name(o)).min().unwrap_or_default(),"active":t.state.contains(&TopState::Activated)})).collect::<Vec<_>>()})
    }
    fn action(&self, a: &[String]) -> Result<Value> {
        let cmd = a[0].as_str();
        let idx = |i: usize| -> Result<&Workspace> {
            let n = a
                .get(i)
                .ok_or(tr("missing workspace"))?
                .parse::<usize>()
                .map_err(|_| tr("invalid workspace"))?;
            self.ordered()
                .get(n.checked_sub(1).ok_or(tr("invalid workspace"))?)
                .copied()
                .ok_or("not_found".into())
        };
        match cmd {
            "workspaces" if a.len() == 1 => return Ok(self.workspace_json()),
            "windows" if a.len() == 1 => return Ok(self.window_json()),
            "set-tiling" if a.len() == 3 => {
                let w = idx(1)?;
                if !w
                    .cosmic_capabilities
                    .contains(WorkspaceCapabilities::SetTilingState)
                {
                    return Err(tr("tiling unavailable").into());
                }
                let mode = match a[2].as_str() {
                    "on" => TilingState::TilingEnabled,
                    "off" => TilingState::FloatingOnly,
                    _ => return Err(tr("expected on or off").into()),
                };
                w.cosmic_handle
                    .as_ref()
                    .ok_or(tr("tiling unavailable"))?
                    .set_tiling_state(mode);
                self.ws
                    .workspace_manager()
                    .get()
                    .map_err(|e| e.to_string())?
                    .commit();
            }
            "move" | "close" | "activate" => {
                if a.len() != if cmd == "move" { 3 } else { 2 } {
                    return Err(tr("invalid arguments").into());
                }
                let t = self
                    .tops
                    .toplevels()
                    .find(|t| t.identifier == a[1])
                    .ok_or("not_found")?;
                let h = t.cosmic_toplevel.as_ref().ok_or(tr("management unavailable"))?;
                let m = &self
                    .manager
                    .as_ref()
                    .ok_or(tr("management unavailable"))?
                    .manager;
                let capability = match cmd {
                    "move" => {
                        manager::ZcosmicToplelevelManagementCapabilitiesV1::MoveToExtWorkspace
                    }
                    "close" => manager::ZcosmicToplelevelManagementCapabilitiesV1::Close,
                    _ => manager::ZcosmicToplelevelManagementCapabilitiesV1::Activate,
                };
                if !self.caps.contains(&WEnum::Value(capability)) {
                    return Err(tr("management capability unavailable").into());
                }
                match cmd {
                    "move" => {
                        if m.version() < 4 {
                            return Err(tr("move requires management v4").into());
                        }
                        m.move_to_ext_workspace(
                            h,
                            &idx(2)?.handle,
                            &self.output().ok_or(tr("no output"))?,
                        );
                    }
                    "close" => m.close(h),
                    _ => m.activate(h, &self.seats.seats().next().ok_or(tr("no seat"))?),
                }
            }
            _ => return Err(tr("invalid arguments").into()),
        };
        Ok(json!({"done":true}))
    }
}
pub fn run(a: &[String]) -> Result<Value> {
    let conn = Connection::connect_to_env().map_err(|e| e.to_string())?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();
    let registry = RegistryState::new(&globals);
    let mut state = State {
        outputs: OutputState::new(&globals, &qh),
        seats: SeatState::new(&globals, &qh),
        ws: WorkspaceState::new(&registry, &qh),
        tops: ToplevelInfoState::try_new(&registry, &qh).ok_or(tr("toplevel protocol unavailable"))?,
        manager: ToplevelManagerState::try_new(&registry, &qh),
        registry,
        caps: vec![],
        info_ready: false,
    };
    // Initial object creation and dependent COSMIC info arrive over successive roundtrips.
    for _ in 0..3 {
        queue.roundtrip(&mut state).map_err(|e| e.to_string())?;
    }
    // COSMIC batches initial toplevel properties on its refresh timer, after sync replies.
    // Roundtrips alone can otherwise incorrectly report an empty desktop.
    let deadline = Instant::now() + Duration::from_millis(500);
    while !state.info_ready && Instant::now() < deadline {
        queue
            .dispatch_pending(&mut state)
            .map_err(|e| e.to_string())?;
        conn.flush().map_err(|e| e.to_string())?;
        if let Some(guard) = queue.prepare_read() {
            let mut fd = libc::pollfd {
                fd: conn.as_fd().as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let n = unsafe { libc::poll(&mut fd, 1, 25) };
            if n < 0 {
                return Err(std::io::Error::last_os_error().to_string());
            }
            if n > 0 {
                guard.read().map_err(|e| e.to_string())?;
            }
        }
    }
    queue
        .dispatch_pending(&mut state)
        .map_err(|e| e.to_string())?;
    if a[0] != "watch" {
        let value = state.action(a)?;
        queue.roundtrip(&mut state).map_err(|e| e.to_string())?;
        return Ok(value);
    }
    if a.len() != 1 {
        return Err(tr("invalid arguments").into());
    }
    let mut old_ws = state.workspace_json();
    let mut old_windows = state.window_json();
    // Initial active workspace is a useful snapshot; preexisting windows are not window_new.
    if let Some(w) = old_ws["workspaces"]
        .as_array()
        .and_then(|w| w.iter().find(|w| w["active"] == true))
    {
        emit(json!({"event":"workspace","index":w["index"]}))?;
    }
    loop {
        queue
            .dispatch_pending(&mut state)
            .map_err(|e| e.to_string())?;
        let ws = state.workspace_json();
        let windows = state.window_json();
        let active = |v: &Value| {
            v["workspaces"]
                .as_array()
                .and_then(|w| w.iter().find(|w| w["active"] == true))
                .map(|w| w["index"].clone())
        };
        if active(&ws) != active(&old_ws) {
            if let Some(index) = active(&ws) {
                emit(json!({"event":"workspace","index":index}))?;
            }
        }
        let keyed = |v: &Value| -> BTreeMap<String, Value> {
            v["windows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|w| (w["id"].as_str().unwrap_or_default().into(), w.clone()))
                .collect()
        };
        let old = keyed(&old_windows);
        let new = keyed(&windows);
        for (id, w) in &new {
            match old.get(id) {
                None => emit(
                    json!({"event":"window_new","id":id,"app_id":w["app_id"],"workspace":w["workspace"]}),
                )?,
                Some(prev) if prev["workspace"] != w["workspace"] => {
                    emit(json!({"event":"window_moved","id":id,"workspace":w["workspace"]}))?
                }
                _ => {}
            }
        }
        for id in old.keys().filter(|id| !new.contains_key(*id)) {
            emit(json!({"event":"window_closed","id":id}))?;
        }
        old_ws = ws;
        old_windows = windows;
        conn.flush().map_err(|e| e.to_string())?;
        if let Some(guard) = queue.prepare_read() {
            let mut fds = [
                libc::pollfd {
                    fd: conn.as_fd().as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: 0,
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            let n = unsafe { libc::poll(fds.as_mut_ptr(), 2, 1000) };
            if n < 0 {
                return Err(std::io::Error::last_os_error().to_string());
            }
            if fds[1].revents != 0 {
                let mut b = [0; 256];
                if std::io::stdin().read(&mut b).map_err(|e| e.to_string())? == 0 {
                    return Ok(Value::Null);
                }
            }
            if fds[0].revents != 0 {
                guard.read().map_err(|e| e.to_string())?;
            }
        }
    }
}
fn emit(v: Value) -> Result<()> {
    let mut out = std::io::stdout().lock();
    writeln!(out, "{v}")
        .and_then(|_| out.flush())
        .map_err(|e| e.to_string())
}
