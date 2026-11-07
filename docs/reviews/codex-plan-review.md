# Critical review before implementation

The split is workable, but the compositor integration must use the protocols actually advertised by COSMIC 1.11. Workspace indices are transient presentation order, not persistent IDs. Multiple outputs and empty/dynamic workspaces need explicit handling; a helper must not invent a destination when none exists. Toplevel identifiers must come from the compositor, not process-local proxy IDs, because commands open separate connections.

Theme import must persist both ThemeBuilder and its built Theme and then mode, using cosmic-theme's typed config API. Palette overrides and an explicit mode override must agree. A native exported builder is not an Omarchy palette; terminal colors derived from it are an approximation. Null corners must preserve the current radii.

Terminal config cannot be guessed from the desktop theme schema. Verify the installed terminal's schema before writing; preserve unrelated custom schemes and use the fixed Maprisma prefix. Config write tests must be isolated in a temporary XDG_CONFIG_HOME.

Automation needs an initial compositor snapshot, reconnect/error handling, bounded queues and subprocess deadlines. Watch must stop on stdin EOF even while the compositor is idle. Overflow should only react to newly mapped windows, never to user moves; unavailable destinations should leave the window alone. Autostart needs an atomic session marker, not a persistent marker across logins.

The popup needs explicit loading/error/empty states. A long-running GUI toggle cannot be treated like a short core request and killed after 60 seconds. Executables should be resolved next to the applet before PATH. Installation is separate from building and must not change the panel.
