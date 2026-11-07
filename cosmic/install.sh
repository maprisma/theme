#!/usr/bin/env bash
# Build/install only. Panel placement remains a separate user action.
set -euo pipefail
cd "$(dirname "$0")"
maprisma_id=io.github.ubruckhaus.CosmicMaprismaTheme
maprisma_data="${XDG_DATA_HOME:-$HOME/.local/share}"
maprisma_bin="$HOME/.local/bin"
cargo build --release --offline
install -Dm755 target/release/maprisma-theme-helper "$maprisma_bin/maprisma-theme-helper"
install -Dm755 target/release/cosmic-maprisma-theme-applet "$maprisma_bin/cosmic-maprisma-theme-applet"
mkdir -p "$maprisma_data/applications"
# Quote the executable path according to the desktop entry specification.
python3 - "$maprisma_bin/cosmic-maprisma-theme-applet" "applet/data/$maprisma_id.desktop" "$maprisma_data/applications/$maprisma_id.desktop" <<'PY'
import pathlib, sys
exe, source, target = sys.argv[1:]
quoted = '"' + ''.join('\\' + c if c in '\\"`$' else c for c in exe).replace('%', '%%') + '"'
text = pathlib.Path(source).read_text()
pathlib.Path(target).write_text('\n'.join('Exec=' + quoted if line.startswith('Exec=') else line for line in text.splitlines()) + '\n')
PY
install -Dm644 "applet/data/icons/$maprisma_id-symbolic.svg" "$maprisma_data/icons/hicolor/scalable/apps/$maprisma_id-symbolic.svg"
if command -v gtk-update-icon-cache >/dev/null; then gtk-update-icon-cache -f -t "$maprisma_data/icons/hicolor" || true; fi
printf '%s\n' 'Installed Maprisma Theme helper and applet. Panel configuration was not changed.'
