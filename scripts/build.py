#!/usr/bin/env python3
"""
One-command build for baihu_qcxs KernelSU module.

Usage:
  python scripts/build.py                    # build + zip
  python scripts/build.py --version vX.Y.Z   # set version in module/prop then build + zip
  python scripts/build.py --push             # build + zip + push to device
  python scripts/build.py --install          # build + zip + push + ksud install
  python scripts/build.py --webui-only       # only rebuild Vue frontend
  python scripts/build.py --module-only      # only re-zip module/ (skip webui)

Requirements:
  - Node.js 20+ (for Vue build)
  - adb (for --push / --install)
"""

import os, sys, shutil, subprocess, zipfile, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBUI_DIR = os.path.join(ROOT, 'webui')
MODULE_DIR = os.path.join(ROOT, 'module')
DIST_DIR = os.path.join(ROOT, 'dist')
OUTPUT_ZIP = os.path.join(DIST_DIR, 'baihu_qcxs.zip')
BAIHU_BIN = os.path.join(MODULE_DIR, 'bin', 'baihu')
BAIHU_LIB_DIR = os.path.join(MODULE_DIR, 'bin', 'lib')
BAIHU_MANIFEST = os.path.join(BAIHU_LIB_DIR, 'manifest.txt')

EXCLUDE_IN_ZIP = {'.git', '__pycache__', '*.pyc', '.DS_Store'}

def log(msg):
    print(f'  >> {msg}')

def run(cmd, cwd=None):
    log(f'Running: {cmd}')
    subprocess.run(cmd, shell=True, cwd=cwd or ROOT, check=True)

def build_webui():
    """Build Vue 3 frontend with Vite."""
    if not os.path.exists(os.path.join(WEBUI_DIR, 'node_modules')):
        log('Installing npm dependencies...')
        run('npm install', cwd=WEBUI_DIR)
    log('Building Vue frontend...')
    run('npm run build', cwd=WEBUI_DIR)

def sync_webroot():
    """Copy webui/dist/ → module/webroot/."""
    src = os.path.join(WEBUI_DIR, 'dist')
    dst = os.path.join(MODULE_DIR, 'webroot')
    if not os.path.exists(src):
        log('ERROR: webui/dist/ not found. Run build first.')
        sys.exit(1)
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    log(f'Copied webui/dist/ → module/webroot/ ({len(os.listdir(dst))} items)')

def combine_baihu():
    """Concatenate module/bin/lib/*.sh into bin/baihu in the order declared by
    bin/lib/manifest.txt.

    The baihu control script is developed as modular fragments under bin/lib/ so
    individual sections stay small and easy to read, but ships as a single file
    so the on-device layout (sourced by customize.sh / service.sh, run via the
    system/bin/baihu wrapper) is unchanged. Ordering is declared in the manifest
    rather than inferred from filenames, so a new fragment can be inserted in the
    middle without renumbering existing files.
    """
    if not os.path.isfile(BAIHU_MANIFEST):
        log(f'ERROR: merge manifest missing: {BAIHU_MANIFEST}')
        sys.exit(1)

    # Collect declared fragments, ignoring blank lines and # comments.
    frags = []
    with open(BAIHU_MANIFEST, encoding='utf-8', newline='') as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            # Entries must be bare filenames (no paths) living next to the manifest.
            if os.path.dirname(line) or line != os.path.basename(line):
                log(f'ERROR: manifest entry {line!r} must be a bare filename in bin/lib/')
                sys.exit(1)
            frags.append(line)

    if not frags:
        log('ERROR: manifest lists no fragments')
        sys.exit(1)

    # Fail fast if a declared fragment is missing (typo, renamed/moved file...).
    missing = [f for f in frags if not os.path.isfile(os.path.join(BAIHU_LIB_DIR, f))]
    if missing:
        log('ERROR: manifest references missing fragment(s): ' + ', '.join(missing))
        sys.exit(1)

    # Warn about fragments on disk that are not registered in the manifest, so a
    # newly added section is never silently dropped.
    on_disk = {f for f in os.listdir(BAIHU_LIB_DIR) if f.endswith('.sh')}
    unlisted = sorted(on_disk - set(frags))
    if unlisted:
        log('WARNING: fragment(s) on disk but not in manifest (will NOT be merged): '
            + ', '.join(unlisted))

    parts = []
    for f in frags:
        path = os.path.join(BAIHU_LIB_DIR, f)
        # newline='' so LF stays LF and is not translated to CRLF on Windows.
        with open(path, encoding='utf-8', newline='') as fh:
            parts.append(fh.read().rstrip('\n'))
    merged = '\n'.join(parts) + '\n'
    # newline='' keeps the file LF-only: CRLF breaks toybox sh parsing.
    with open(BAIHU_BIN, 'w', encoding='utf-8', newline='') as fh:
        fh.write(merged)
    os.chmod(BAIHU_BIN, 0o755)
    log(f'Merged {len(frags)} lib fragments (manifest order) -> bin/baihu ({len(merged)} bytes)')

def pack_zip():
    """Pack module/ into a KernelSU-compatible zip."""
    # Always (re)build bin/baihu from lib/ fragments first so the zip ships the
    # latest merged script, regardless of whether it was edited in the repo.
    combine_baihu()
    os.makedirs(DIST_DIR, exist_ok=True)
    if os.path.exists(OUTPUT_ZIP):
        os.remove(OUTPUT_ZIP)

    def should_exclude(name):
        for pat in EXCLUDE_IN_ZIP:
            if pat.startswith('*'):
                if name.endswith(pat[1:]):
                    return True
            elif name == pat:
                return True
        return False

    def perm(name):
        base = os.path.basename(name)
        if name.startswith('bin/') or base == 'update-binary' or name.endswith('.sh'):
            return 0o755
        if name.startswith('webroot/'):
            return 0o644
        return 0o644

    with zipfile.ZipFile(OUTPUT_ZIP, 'w', zipfile.ZIP_DEFLATED) as z:
        for dirpath, dirnames, filenames in os.walk(MODULE_DIR):
            # Filter exclusions
            dirnames[:] = [d for d in dirnames if d not in EXCLUDE_IN_ZIP and not d.startswith('.')]
            for fn in filenames:
                if should_exclude(fn):
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, MODULE_DIR).replace('\\', '/')
                # lib/*.sh are build-time fragments merged into bin/baihu; never ship them.
                if rel.startswith('bin/lib/'):
                    continue
                if rel.split('/')[0] in EXCLUDE_IN_ZIP:
                    continue
                info = zipfile.ZipInfo(rel, date_time=(2026, 9, 4, 0, 0, 0))
                info.external_attr = (0o100000 | perm(rel)) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(full, 'rb') as f:
                    z.writestr(info, f.read())

    size = os.path.getsize(OUTPUT_ZIP)
    log(f'Packed {OUTPUT_ZIP} ({size/1024/1024:.1f} MB, {len(z.infolist())} files)')

def push_to_device():
    """Push zip to device via adb."""
    log('Pushing to device...')
    run(f'adb push "{OUTPUT_ZIP}" /data/local/tmp/baihu_qcxs.zip')

def install_on_device():
    """Install module via ksud."""
    push_to_device()
    log('Installing via ksud...')
    run('adb shell "su 0 /data/adb/ksu/bin/ksud module install /data/local/tmp/baihu_qcxs.zip 2>&1"')

def set_version(version):
    """Update module/module.prop version and versionCode from a tag like 'v1.2.3'."""
    prop = os.path.join(MODULE_DIR, 'module.prop')
    ver = version.lstrip('v')
    # versionCode: derive integer from x.y.z -> x*10000+y*100+z (v1.2.3 -> 10203)
    parts = [int(p) for p in ver.replace('-', '.').split('.')[:3]]
    while len(parts) < 3:
        parts.append(0)
    code = parts[0] * 10000 + parts[1] * 100 + parts[2]

    text = open(prop, encoding='utf-8').read()
    lines = text.splitlines()
    out = []
    replaced = {'version': False, 'versionCode': False}
    for ln in lines:
        if ln.startswith('version=') and not replaced['version']:
            out.append(f'version=v{ver}'); replaced['version'] = True
        elif ln.startswith('versionCode=') and not replaced['versionCode']:
            out.append(f'versionCode={code}'); replaced['versionCode'] = True
        else:
            out.append(ln)
    if not replaced['version']:
        out.append(f'version=v{ver}')
    if not replaced['versionCode']:
        out.append(f'versionCode={code}')
    open(prop, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
    log(f'Set module version=v{ver} versionCode={code}')

def push_webui_to_device():
    """Push updated webroot directly to module dir (no reboot needed)."""
    src = os.path.join(WEBUI_DIR, 'dist')
    if not os.path.exists(src):
        log('ERROR: webui/dist/ not found. Run build first.')
        sys.exit(1)
    log('Pushing webroot to device (immediate update)...')
    tmp = '/data/local/tmp/baihu_webroot'
    run(f'adb shell "su 0 rm -rf {tmp}"')
    run(f'adb push "{src}/." {tmp}/')
    run(f'adb shell "su 0 cp -r {tmp}/* /data/adb/modules/baihu_qcxs/webroot/ && su 0 rm -rf {tmp}"')

def main():
    parser = argparse.ArgumentParser(description='Build baihu_qcxs module')
    parser.add_argument('--push', action='store_true', help='Push zip to device after build')
    parser.add_argument('--install', action='store_true', help='Install on device via ksud after build')
    parser.add_argument('--webui-only', action='store_true', help='Only rebuild Vue frontend')
    parser.add_argument('--module-only', action='store_true', help='Only re-zip module/ (skip webui)')
    parser.add_argument('--push-webui', action='store_true', help='Push webroot to device directly (no reboot)')
    parser.add_argument('--version', help='Set module version (e.g. v1.2.3) before building')
    args = parser.parse_args()

    if args.version:
        set_version(args.version)

    if args.push_webui:
        # Special fast path: rebuild webui and push live
        build_webui()
        push_webui_to_device()
        log('WebUI updated! Refresh KernelSU Manager to see changes.')
        return

    if args.webui_only:
        build_webui()
        sync_webroot()
        return

    if args.module_only:
        pack_zip()
        return

    # Full build
    build_webui()
    sync_webroot()
    pack_zip()

    if args.push:
        push_to_device()
    elif args.install:
        install_on_device()

    log('Done!')

if __name__ == '__main__':
    main()