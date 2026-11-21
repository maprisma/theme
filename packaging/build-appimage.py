#!/usr/bin/env python3
"""The Maprisma Theme AppImage (after Maprisma Launcher's packaging/build-appimage.py), made from the release
tarball (tools/build-release.py): dist/Maprisma-Theme-<version>-x86_64.AppImage and its SHA-256.

The AppDir holds the tarball's app/ as usr/lib/maprisma-theme, its share/ files as usr/share, and at the
top the desktop entry, the icon and an AppRun that starts usr/lib/maprisma-theme/maprisma-theme, or with
`core` as the first argument the core CLI (`<AppImage> core daemon`, `<AppImage> core apply <slug>`: what
keyboard shortcuts run when no copy is installed). appimagetool and its runtime are pinned, checked files
(no download while building):

    packaging/build-appimage.py [--tool <appimagetool>] [--runtime <runtime-x86_64>]

defaults ~/Applications/appimagetool-1.9.1-x86_64.AppImage and
~/Applications/appimage-runtime-20251108-x86_64 (AppImage/type2-runtime release 20251108).
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'com.maprisma.Theme'
TOOL = Path.home() / 'Applications/appimagetool-1.9.1-x86_64.AppImage'
TOOL_SHA = 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'
RUNTIME = Path.home() / 'Applications/appimage-runtime-20251108-x86_64'
RUNTIME_SHA = '2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'
APPRUN = '''#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
if [ "${1:-}" = core ]; then
  shift
  exec "$here/usr/lib/maprisma-theme/bin/maprisma-theme-core" "$@"
fi
exec "$here/usr/lib/maprisma-theme/maprisma-theme" "$@"
'''


def checked(path: Path, sha: str) -> Path:
    if not path.is_file():
        sys.exit(f'{path} is missing')
    if hashlib.sha256(path.read_bytes()).hexdigest() != sha:
        sys.exit(f'{path} is not the pinned file (SHA-256 differs)')
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--tool', type=Path, default=TOOL)
    parser.add_argument('--runtime', type=Path, default=RUNTIME)
    args = parser.parse_args()
    sys.path.insert(0, str(ROOT / 'tools'))
    ver = __import__('importlib').import_module('build-release').version()
    tool = checked(args.tool, TOOL_SHA) if args.tool == TOOL else args.tool
    runtime = checked(args.runtime, RUNTIME_SHA) if args.runtime == RUNTIME else args.runtime
    dist = ROOT / 'dist'
    archive = dist / f'maprisma-theme-{ver}-x86_64.tar.gz'
    if not archive.is_file():
        sys.exit(f'{archive} is missing: tools/build-release.py first')
    out = dist / f'Maprisma-Theme-{ver}-x86_64.AppImage'
    with tempfile.TemporaryDirectory(prefix='appimage-', dir=dist) as temp:
        with tarfile.open(archive) as tar:
            tar.extractall(temp, filter='data')
        top = Path(temp) / f'maprisma-theme-{ver}'
        appdir = Path(temp) / 'MaprismaTheme.AppDir'
        shutil.copytree(top / 'app', appdir / 'usr/lib/maprisma-theme', symlinks=True)
        shutil.copytree(top / 'share', appdir / 'usr/share')
        shutil.copy2(top / 'LICENSE', appdir / 'usr/share/LICENSE')
        shutil.copy2(appdir / f'usr/share/applications/{APP_ID}.desktop', appdir / f'{APP_ID}.desktop')
        icon = appdir / f'usr/share/icons/hicolor/scalable/apps/{APP_ID}.svg'
        shutil.copy2(icon, appdir / f'{APP_ID}.svg')
        (appdir / '.DirIcon').symlink_to(f'{APP_ID}.svg')
        (appdir / 'AppRun').write_text(APPRUN)
        (appdir / 'AppRun').chmod(0o755)
        out.unlink(missing_ok=True)
        env = {**os.environ, 'ARCH': 'x86_64', 'APPIMAGE_EXTRACT_AND_RUN': '1'}
        subprocess.run([str(tool), '--runtime-file', str(runtime), str(appdir), str(out)],
                       env=env, check=True)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    (dist / f'{out.name}.sha256').write_text(f'{digest}  {out.name}\n')
    print(f'\n{out}\nsha256 {digest}')


if __name__ == '__main__':
    main()
