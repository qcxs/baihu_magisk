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

import os, sys, shutil, subprocess, zipfile, argparse, json, hashlib, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBUI_DIR = os.path.join(ROOT, 'webui')
MODULE_DIR = os.path.join(ROOT, 'module')
TMP_DIR = os.path.join(ROOT, 'tmp')
DIST_DIR = os.path.join(ROOT, 'dist')
OUTPUT_ZIP = os.path.join(DIST_DIR, 'baihu_qcxs.zip')
OUTPUT_OFFLINE_ZIP = os.path.join(DIST_DIR, 'baihu_qcxs_offline.zip')

# Offline layers are downloaded to tmp/offline/ (gitignored) and briefly copied
# to module/offline/ immediately before packing so they end up inside the zip.
# The module-level path is cleaned up right after packing.
OFFLINE_DIR = os.path.join(TMP_DIR, 'offline')
MODULE_OFFLINE_DIR = os.path.join(MODULE_DIR, 'offline')
BAIHU_BIN = os.path.join(MODULE_DIR, 'bin', 'baihu')
BAIHU_LIB_DIR = os.path.join(MODULE_DIR, 'bin', 'lib')
BAIHU_MANIFEST = os.path.join(BAIHU_LIB_DIR, 'manifest.txt')

EXCLUDE_IN_ZIP = {'.git', '__pycache__', '*.pyc', '.DS_Store'}

# Default release version used for local/CI builds when no --version is given.
# The tracked module.prop is kept at this value; --version overrides it with the
# user-supplied release tag, and versionCode is always the git commit count.
DEFAULT_VERSION = "1.0.0"

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

def pack_zip(output_path=None, extra_exclude=None):
    """Pack module/ into a KernelSU-compatible zip.

    Args:
        output_path: Output zip path (default: OUTPUT_ZIP).
        extra_exclude: Extra set of directory/file names to exclude.
    """
    # Always (re)build bin/baihu from lib/ fragments first so the zip ships the
    # latest merged script, regardless of whether it was edited in the repo.
    combine_baihu()

    output = output_path or OUTPUT_ZIP
    exclude = set(EXCLUDE_IN_ZIP)
    if extra_exclude:
        exclude.update(extra_exclude)

    os.makedirs(DIST_DIR, exist_ok=True)
    if os.path.exists(output):
        os.remove(output)

    def should_exclude(name, exclude_set):
        for pat in exclude_set:
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

    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
        for dirpath, dirnames, filenames in os.walk(MODULE_DIR):
            # Filter exclusions
            dirnames[:] = [d for d in dirnames if d not in exclude and not d.startswith('.')]
            for fn in filenames:
                if should_exclude(fn, exclude):
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, MODULE_DIR).replace('\\', '/')
                # lib/*.sh are build-time fragments merged into bin/baihu; never ship them.
                if rel.startswith('bin/lib/'):
                    continue
                if rel.split('/')[0] in exclude:
                    continue
                info = zipfile.ZipInfo(rel, date_time=(2026, 9, 4, 0, 0, 0))
                info.external_attr = (0o100000 | perm(rel)) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                # module.prop: overlay the effective release version/versionCode
                # instead of the pristine repo file (repo file is never mutated).
                if rel == 'module.prop':
                    z.writestr(info, module_prop_bytes())
                else:
                    with open(full, 'rb') as f:
                        z.writestr(info, f.read())

    size = os.path.getsize(output)
    log(f'Packed {output} ({size/1024/1024:.1f} MB, {len(z.infolist())} files)')

def push_to_device():
    """Push zip to device via adb."""
    log('Pushing to device...')
    run(f'adb push "{OUTPUT_ZIP}" /data/local/tmp/baihu_qcxs.zip')

def install_on_device():
    """Install module via ksud."""
    push_to_device()
    log('Installing via ksud...')
    run('adb shell "su 0 /data/adb/ksu/bin/ksud module install /data/local/tmp/baihu_qcxs.zip 2>&1"')

def git_commit_count():
    """Return the number of commits reachable from HEAD.

    versionCode tracks the git commit count so each release gets a larger,
    monotonically increasing integer. Returns None when git is unavailable
    (e.g. the repo was downloaded as a zip without .git), in which case the
    caller keeps the existing versionCode fallback in module.prop.
    """
    try:
        out = subprocess.run(
            ['git', 'rev-list', '--count', 'HEAD'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True,
        ).stdout.decode().strip()
        return int(out)
    except Exception:
        return None

# Release version/versionCode to inject into the packed zip at build time.
# These are kept OUT of the tracked module/module.prop: the repo file always
# holds the default, and the packed zip carries the effective release values,
# so local builds and CI never dirty git with a transient versionCode bump.
PACK_VERSION = None   # e.g. 'v1.2.3' (with 'v' prefix); None => use repo default line
PACK_VERSIONCODE = None  # int (git commit count) or None => keep repo default line

def resolve_release(version):
    """Compute the effective version label + versionCode for this build.

    Args:
        version: user release tag e.g. 'v1.2.3' or '1.2.3', or None for default.

    Sets module-level PACK_VERSION / PACK_VERSIONCODE. Does NOT modify the
    tracked module/module.prop file.
    """
    global PACK_VERSION, PACK_VERSIONCODE
    if version:
        label = 'v' + version.lstrip('v').strip()
    else:
        label = DEFAULT_VERSION if DEFAULT_VERSION.startswith('v') else 'v' + DEFAULT_VERSION
    code = git_commit_count()
    PACK_VERSION = label
    PACK_VERSIONCODE = code
    if code is not None:
        log(f'Release: version={label} versionCode={code} (git commits)')
    else:
        log(f'Release: version={label} (versionCode fallback kept)')

def module_prop_bytes():
    """Return module.prop content with PACK_VERSION / PACK_VERSIONCODE applied.

    The tracked module/module.prop is read (never written); version lines are
    overlaid only in the returned bytes, which is what ends up in the zip.
    """
    prop = os.path.join(MODULE_DIR, 'module.prop')
    text = open(prop, encoding='utf-8', newline='').read()
    lines = text.splitlines()
    out = []
    replaced = {'version': False, 'versionCode': False}
    for ln in lines:
        if ln.startswith('version=') and not replaced['version']:
            out.append(f'version={PACK_VERSION or ln.split("=", 1)[1]}')
            replaced['version'] = True
        elif ln.startswith('versionCode=') and not replaced['versionCode']:
            if PACK_VERSIONCODE is not None:
                out.append(f'versionCode={PACK_VERSIONCODE}')
            else:
                out.append(ln)
            replaced['versionCode'] = True
        else:
            out.append(ln)
    if not replaced['version'] and PACK_VERSION:
        out.append(f'version={PACK_VERSION}')
    if not replaced['versionCode'] and PACK_VERSIONCODE is not None:
        out.append(f'versionCode={PACK_VERSIONCODE}')
    return ('\n'.join(out) + '\n').encode('utf-8')


# ============================================================
# Offline bundle (built-in image layers)
# ============================================================
# The offline bundle pre-packages the OCI image layers for arm64 inside the
# module zip so the device can install without network access. The build script
# downloads the layers from ghcr.io during CI to tmp/offline/ (gitignored),
# copies them briefly into module/offline/ for zipping, then cleans both up.

BAIHU_REPO = "engigu/baihu"
BAIHU_TAG = "latest"
BAIHU_REGISTRY = "https://ghcr.io"
OCI_ARCH = "arm64"


def _oci_token(registry="https://ghcr.io"):
    """Fetch anonymous bearer token from the OCI registry."""
    # The token endpoint is always on the real registry (ghcr.io), not on
    # pull-through mirrors. Mirrors like ghcr.nju.edu.cn forward the token to
    # the upstream, so we always fetch from ghcr.io.
    url = f"https://ghcr.io/token?scope=repository:{BAIHU_REPO}:pull&service=ghcr.io"
    req = urllib.request.Request(url)
    req.add_header('Accept', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
            return data.get('token', '')
    except Exception as e:
        log(f'ERROR: failed to get OCI token: {e}')
        sys.exit(1)


def _oci_fetch(url, accept, token):
    """Fetch a URL with bearer auth + Accept header, return bytes."""
    req = urllib.request.Request(url)
    req.add_header('Authorization', f'Bearer {token}')
    if accept:
        req.add_header('Accept', accept)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        log(f'ERROR: HTTP {e.code} fetching {url}')
        if e.code == 401:
            log('  (ghcr.io returned 401 — the public repo may require auth)')
        sys.exit(1)
    except Exception as e:
        log(f'ERROR: failed to fetch {url}: {e}')
        sys.exit(1)


def _get_module_version():
    """Read the current version from module.prop."""
    prop = os.path.join(MODULE_DIR, 'module.prop')
    try:
        for line in open(prop, encoding='utf-8'):
            if line.startswith('version='):
                return line.strip().split('=', 1)[1]
    except Exception:
        pass
    return None


def fetch_oci_offline(offline_dir, mirror_url=None):
    """Download arm64 OCI manifest + config + all layers into offline_dir.

    Args:
        offline_dir: Target directory (use tmp/offline/ — gitignored).
        mirror_url: OCI registry mirror URL (e.g. https://ghcr.nju.edu.cn).
            Defaults to https://ghcr.io.

    Creates the following structure:
      offline_dir/
        manifest.json     # arch-specific OCI manifest
        config.json       # image config blob
        layers.txt        # tab-separated digest/size/mediaType per layer
        .image_digest     # IMAGE_DIGEST=sha256sum-of-all-layer-digests
        bundle.info       # provenance: repo, tag, arch, source, module version
        layers/
          layer-001       # gzipped layer tarball
          layer-002       # ...
    """
    registry = (mirror_url or BAIHU_REGISTRY).rstrip('/')
    log(f'Fetching arm64 OCI image layers for offline bundle from {registry}...')
    token = _oci_token()

    # --- Step 1: fetch index manifest ---
    index_url = f"{registry}/v2/{BAIHU_REPO}/manifests/{BAIHU_TAG}"
    accept_idx = (
        "application/vnd.oci.image.index.v1+json,"
        "application/vnd.docker.distribution.manifest.list.v2+json"
    )
    raw = _oci_fetch(index_url, accept_idx, token)
    index = json.loads(raw)

    # --- Step 2: find arm64 digest in the index ---
    arch_digest = None
    if 'manifests' in index:
        for m in index['manifests']:
            if m.get('platform', {}).get('architecture') == OCI_ARCH:
                arch_digest = m['digest']
                break
        if not arch_digest:
            log(f'ERROR: no {OCI_ARCH} manifest found in index')
            sys.exit(1)
        # Fetch the arch-specific manifest
        accept_manifest = (
            "application/vnd.oci.image.manifest.v1+json,"
            "application/vnd.docker.distribution.manifest.v2+json"
        )
        raw = _oci_fetch(
            f"{registry}/v2/{BAIHU_REPO}/manifests/{arch_digest}",
            accept_manifest, token
        )
        manifest = json.loads(raw)
    else:
        # Direct manifest (single-arch image)
        manifest = index

    # Write manifest.json
    os.makedirs(offline_dir, exist_ok=True)
    with open(os.path.join(offline_dir, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, indent=2)

    # --- Step 3: fetch config blob ---
    config_digest = manifest['config']['digest']
    raw = _oci_fetch(
        f"{registry}/v2/{BAIHU_REPO}/blobs/{config_digest}",
        '', token
    )
    config = json.loads(raw)
    with open(os.path.join(offline_dir, 'config.json'), 'w') as f:
        json.dump(config, f, indent=2)

    # --- Step 4: download layers ---
    layers_dir = os.path.join(offline_dir, 'layers')
    os.makedirs(layers_dir, exist_ok=True)

    layer_entries = []
    total_hasher = hashlib.sha256()
    total = len(manifest['layers'])

    for i, layer in enumerate(manifest['layers'], 1):
        digest = layer['digest']
        size = layer['size']
        media_type = layer.get('mediaType', '')
        layer_entries.append(f"{digest}\t{size}\t{media_type}\n")
        total_hasher.update(digest.encode())

        layer_name = f"layer-{i:03d}"
        layer_file = os.path.join(layers_dir, layer_name)
        sha_expected = digest.replace('sha256:', '')

        log(f'  [{i}/{total}] {layer_name} ({size / 1024 / 1024:.1f} MB)')

        raw = _oci_fetch(
            f"{registry}/v2/{BAIHU_REPO}/blobs/{digest}",
            '', token
        )

        # Verify sha256
        actual_sha = hashlib.sha256(raw).hexdigest()
        if actual_sha != sha_expected:
            log(f'ERROR: {layer_name} sha256 mismatch '
                f'(expected {sha_expected}, got {actual_sha})')
            sys.exit(1)

        with open(layer_file, 'wb') as f:
            f.write(raw)

        log(f'    verified sha256: {actual_sha[:16]}... OK')

    # Write layers.txt
    with open(os.path.join(offline_dir, 'layers.txt'), 'w') as f:
        f.writelines(layer_entries)

    # Write .image_digest (cumulative hash of all layer digests)
    image_digest = total_hasher.hexdigest()
    with open(os.path.join(offline_dir, '.image_digest'), 'w') as f:
        f.write(f"IMAGE_DIGEST={image_digest}\n")

    # Write bundle.info (provenance metadata). Prefer the effective release
    # version injected at pack time, falling back to the tracked file.
    mod_ver = PACK_VERSION or _get_module_version() or 'unknown'
    with open(os.path.join(offline_dir, 'bundle.info'), 'w') as f:
        f.write(f"BAIHU_REPO={BAIHU_REPO}\n")
        f.write(f"BAIHU_TAG={BAIHU_TAG}\n")
        f.write(f"BAIHU_ARCH={OCI_ARCH}\n")
        f.write(f"SOURCE_MIRROR={registry}\n")
        f.write(f"MODULE_VERSION={mod_ver}\n")

    log(f'Offline layers prepared: {total} layers, '
        f'{sum(l["size"] for l in manifest["layers"]) / 1024 / 1024:.0f} MB raw')
    return True


def pack_offline_zip(mirror_url=None):
    """Build the offline bundle zip (includes bundled arm64 OCI layers).

    Args:
        mirror_url: OCI registry mirror URL for downloading layers.
            Defaults to https://ghcr.io.

    1. Download OCI layers to tmp/offline/ (gitignored).
    2. Copy to module/offline/ for packing.
    3. Pack the full module/ (including offline/).
    4. Clean up both tmp/offline/ and module/offline/.
    """
    # Clean any stale offline dirs from a previous failed run
    for d in (OFFLINE_DIR, MODULE_OFFLINE_DIR):
        if os.path.exists(d):
            shutil.rmtree(d)

    fetch_oci_offline(OFFLINE_DIR, mirror_url=mirror_url)

    # Briefly copy into module/ so pack_zip picks it up
    shutil.copytree(OFFLINE_DIR, MODULE_OFFLINE_DIR)

    # Regenerate bin/baihu inside pack_zip (via combine_baihu) so the fragment
    # merge is always fresh. The extra_exclude set is deliberately empty here:
    # we WANT the offline/ dir to be included.
    pack_zip(output_path=OUTPUT_OFFLINE_ZIP, extra_exclude=set())

    # Clean up — the offline data is inside the zip
    for d in (OFFLINE_DIR, MODULE_OFFLINE_DIR):
        if os.path.exists(d):
            shutil.rmtree(d)
    log('Cleaned up module/offline/')

    offline_size = os.path.getsize(OUTPUT_OFFLINE_ZIP)
    online_size = os.path.getsize(OUTPUT_ZIP)
    log(f'Online  zip: {online_size / 1024 / 1024:.1f} MB')
    log(f'Offline zip: {offline_size / 1024 / 1024:.1f} MB')

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
    parser.add_argument('--offline-bundle', action='store_true',
                        help='Build offline bundle (includes arm64 OCI layers)')
    parser.add_argument('--offline-mirror',
                        help='Mirror URL for offline bundle download (default: https://ghcr.io)')
    args = parser.parse_args()

    # Version logic (compute-only; never mutates the tracked module/prop):
    #   --version → explicit release version
    #   --offline-bundle without --version → keep the repo default version line
    #   otherwise → overlay the default release version (1.0.0)
    if args.version:
        resolve_release(args.version)
    elif args.offline_bundle:
        resolve_release(None)
    elif not (args.push_webui or args.webui_only):
        resolve_release(None)

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

    if args.offline_bundle:
        # Build webui unless --module-only also given (reuse existing webroot)
        if not args.module_only:
            build_webui()
            sync_webroot()
        pack_offline_zip(mirror_url=args.offline_mirror)
        return

    if args.module_only:
        # Online build: exclude offline/ from the zip
        pack_zip(extra_exclude={'offline'})
        return

    # Full build (online)
    build_webui()
    sync_webroot()
    pack_zip(extra_exclude={'offline'})

    if args.push:
        push_to_device()
    elif args.install:
        install_on_device()

    log('Done!')

if __name__ == '__main__':
    main()