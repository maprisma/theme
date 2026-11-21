#!/usr/bin/env python3
"""Build a Maprisma Theme release: dist/maprisma-theme-<version>-x86_64.tar.gz and its SHA-256
(after Maprisma Launcher's tools/build-release.py).

Built in a clean copy of the git-tracked files (no local theme artwork: themes/*/backgrounds and
the preview pictures are not part of the repository), in release mode, the release identity
checked, and one folder maprisma-theme-<version>/ with:
    app/                      what tools/install-local puts in ~/.local/lib/maprisma-theme: the bundle
                              (maprisma-theme, lib/, data/), bin/ (maprisma-theme-core, -helper,
                              -applet) and share/maprisma-theme (themes, templates)
    share/applications/       com.maprisma.Theme.desktop, the COSMIC applet's entry
    share/icons/hicolor/scalable/apps/   the app's and the applet's icons
    autostart/                com.maprisma.Theme.Daemon.desktop (the tray/automation daemon; KDE, Hyprland)
    LICENSE
The AppImage is made from it (packaging/build-appimage.py).

    tools/build-release.py
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'com.maprisma.Theme'
APPLET_ID = 'io.github.ubruckhaus.CosmicMaprismaTheme'
BINARY = 'maprisma-theme'
FLUTTER = ['flutter', '--suppress-analytics', '--no-version-check']


def version() -> str:
    found = re.search(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)', (ROOT / 'flutter_app/pubspec.yaml').read_text(), re.M)
    if not found:
        sys.exit('no version in flutter_app/pubspec.yaml')
    return found.group(1)


def check_identity(stage: Path, ver: str):
    cmake = (stage / 'flutter_app/linux/CMakeLists.txt').read_text()
    if f'set(APPLICATION_ID "{APP_ID}")' not in cmake or f'set(BINARY_NAME "{BINARY}")' not in cmake:
        sys.exit('Unexpected application id or binary name in flutter_app/linux/CMakeLists.txt')
    core = (stage / 'packages/maprisma_theme_core/lib/src/core.dart').read_text()
    if f"const coreVersion = '{ver}';" not in core:
        sys.exit(f'coreVersion in maprisma_theme_core is not {ver}')


def tracked_copy(stage: Path):
    """The git-tracked files as they are in the working tree."""
    files = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, check=True, capture_output=True).stdout
    for name in files.decode().split('\0'):
        source = ROOT / name
        if not name or not source.is_file():
            continue
        target = stage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)


def main():
    ver = version()
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    env = {**os.environ, 'PATH': f"{os.environ.get('FLUTTER', '/mnt/Data/flutter/bin')}:{os.environ['PATH']}",
           # the crates built once are reused (the clean copy has no target/)
           'CARGO_TARGET_DIR': str(ROOT / 'cosmic/target')}
    with tempfile.TemporaryDirectory(prefix='release-', dir=dist) as temp:
        stage = Path(temp) / 'src'
        tracked_copy(stage)
        check_identity(stage, ver)
        subprocess.run([sys.executable, 'tools/gen-translations'], cwd=stage, check=True, env=env)
        app = stage / 'flutter_app'
        subprocess.run([*FLUTTER, 'pub', 'get', '--offline'], cwd=app, check=True, env=env)
        subprocess.run([*FLUTTER, 'build', 'linux', '--release', '--no-pub', '--no-tree-shake-icons'],
                       cwd=app, check=True, env=env)
        bundle = app / 'build/linux/x64/release/bundle'
        if not (bundle / BINARY).is_file():
            sys.exit(f'no {BINARY} in the bundle')
        (bundle / 'bin').mkdir(exist_ok=True)
        core = stage / 'packages/maprisma_theme_core'
        subprocess.run(['dart', 'pub', 'get', '--offline'], cwd=core, check=True, env=env)
        subprocess.run(['dart', 'compile', 'exe', 'bin/maprisma_theme_core.dart',
                        '-o', str(bundle / 'bin/maprisma-theme-core')], cwd=core, check=True, env=env)
        subprocess.run(['cargo', 'build', '--release', '--offline'], cwd=stage / 'cosmic', check=True, env=env)
        for name in ('maprisma-theme-helper', 'maprisma-theme-applet'):
            shutil.copy2(ROOT / 'cosmic/target/release' / name, bundle / 'bin' / name)
        data = bundle / 'share/maprisma-theme'
        shutil.rmtree(bundle / 'share', ignore_errors=True)
        data.mkdir(parents=True)
        shutil.copytree(stage / 'themes', data / 'themes', symlinks=True)
        shutil.copytree(stage / 'templates', data / 'templates', symlinks=True)

        top = Path(temp) / f'{BINARY}-{ver}'
        shutil.copytree(bundle, top / 'app', symlinks=True)
        apps = top / 'share/applications'
        icons = top / 'share/icons/hicolor/scalable/apps'
        apps.mkdir(parents=True)
        icons.mkdir(parents=True)
        shutil.copy2(stage / f'packaging/{APP_ID}.desktop', apps)
        shutil.copy2(stage / f'cosmic/applet/data/{APPLET_ID}.desktop', apps)
        shutil.copy2(stage / f'packaging/{APP_ID}.svg', icons)
        for icon in sorted((stage / 'cosmic/applet/data/icons').glob('*.svg')):
            shutil.copy2(icon, icons)
        (top / 'autostart').mkdir()
        shutil.copy2(stage / f'packaging/{APP_ID}.Daemon.desktop', top / 'autostart')
        shutil.copy2(stage / 'LICENSE', top / 'LICENSE')
        archive = dist / f'{BINARY}-{ver}-x86_64.tar.gz'

        def owned(info):          # root-owned in any package made from it, no build user's names
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            return info
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(top, arcname=top.name, filter=owned)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist / f'{archive.name}.sha256').write_text(f'{digest}  {archive.name}\n')
    print(f'\n{archive}\nsha256 {digest}')


if __name__ == '__main__':
    main()
