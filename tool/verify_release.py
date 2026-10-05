"""Deterministic release checks for the NSIS-packaged Windows build of this repo.

Five checks, one line each, exit 0 only when all of them pass: version
declarations agree, the built exe really carries that version, nothing in the
source is newer than the build, the staging dir holds no runtime data, and every
delivery dir holds a byte-identical package under the size limit.

Paths resolve against the repo this script lives in, so a clone runs it as-is:
`python tool/verify_release.py` (that's the form shown in README's 自己构建 section).
Where the package is archived outside the repo (the release machine's five delivery
slots) pass those dirs with `--delivery`.
"""
import argparse
import base64
import datetime
import hashlib
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# The repo root is tool/'s parent - derived instead of hardcoded so a clone needs
# no flags.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# What actually ships: Dart snapshot + assets + native runner. `test/` is excluded
# on purpose - editing a test does not make the packaged binary stale.
SRC_DIRS = ["lib", "assets", "windows/runner", "tool"]
SRC_FILES = ["pubspec.yaml", "windows/CMakeLists.txt"]

AP = argparse.ArgumentParser()
AP.add_argument("--repo", default=REPO)
AP.add_argument("--exe", default="ParseDownloader.exe")
AP.add_argument("--version", default="", help="override; else read from --script")
AP.add_argument("--script", default="installer/build_installer.py")
AP.add_argument("--nsi", default="installer/解析下载器.nsi")
AP.add_argument("--app-dart", default="lib/app.dart")
AP.add_argument("--pkg-tpl", default="解析下载器_{version}_x64-setup.exe")
AP.add_argument("--delivery", nargs="*", default=[
    os.path.join(REPO, "build", "dist"),
    os.path.join(REPO, "installer"),
], help="dirs that must each hold the identical package")
AP.add_argument("--staging", default="build/staging")
AP.add_argument("--leak", nargs="*", default=["userdata"],
                help="path fragments that must never reach the package")
AP.add_argument("--max-mb", type=float, default=20.0)
AP.add_argument("--skip-decls", nargs="*", default=[],
                help="declaration labels allowed to be missing in this repo")


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", errors="replace")


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def hm(t):
    return datetime.datetime.fromtimestamp(t).strftime("%m-%d %H:%M")


def exe_version(path):
    """Read the PE version resource - the only trustworthy 'which build is this'.

    Values come back base64'd: powershell.exe writes the console in the OEM code
    page, so a Chinese FileDescription decoded as UTF-8 arrives as mojibake.
    """
    ps = ("$i=(Get-Item -LiteralPath '" + path.replace("'", "''") + "').VersionInfo; "
          "$s=$i.FileVersion+'|'+$i.OriginalFilename+'|'+$i.FileDescription; "
          "[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))")
    r = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps], capture_output=True, text=True)
    try:
        got = __import__("base64").b64decode((r.stdout or "").strip()).decode("utf-8", errors="replace")
    except Exception:
        return {}
    parts = got.split("|")
    return dict(zip(("FileVersion", "OriginalFilename", "FileDescription"), parts)) \
        if len(parts) == 3 else {}


def check(ok, label, detail):
    print(f"[{label}] {'OK' if ok else 'FAIL'}  {detail}")
    return bool(ok)


def main():
    a = AP.parse_args()
    J = lambda *p: os.path.join(a.repo, *p)
    rel = J("build", "windows", "x64", "runner", "Release")
    exe = os.path.join(rel, a.exe)
    app_so = os.path.join(rel, "data", "app.so")
    results = []

    specs = [
        ("pubspec", J("pubspec.yaml"), r"^version:\s*(\S+)"),
        ("kAppVersion", J(a.app_dart.replace("/", os.sep)), r"kAppVersion\s*=\s*['\"]([^'\"]+)"),
        ("installer-script", J(a.script.replace("/", os.sep)), r"VERSION\s*=\s*[\"']([^\"']+)[\"']"),
        ("nsi-fallback", J(a.nsi.replace("/", os.sep)), r"!define\s+VERSION\s+[\"']([^\"']+)[\"']"),
    ]
    decls = {}
    for label, path, rx in specs:
        val = "absent"
        if os.path.exists(path):
            m = re.search(rx, read(path), re.M)
            val = m.group(1) if m else "not-found"
        decls[label] = val
    version = a.version or decls["installer-script"]
    live = {k: v for k, v in decls.items() if k not in a.skip_decls}

    def vmatch(v):
        v = v.split("+")[0]
        return v == version or v.startswith(version + ".")

    results.append(check(
        version not in ("", "absent", "not-found") and all(vmatch(v) for v in live.values()),
        "version-decls", f"expect={version}  " + "  ".join(f"{k}={v}" for k, v in decls.items())))

    built = os.path.getmtime(app_so if os.path.exists(app_so) else exe) if os.path.exists(exe) else 0
    if not os.path.exists(exe):
        results.append(check(False, "exe-version", f"missing {exe} - run flutter build first"))
    else:
        vi = exe_version(exe)
        results.append(check(vi.get("FileVersion", "").startswith(version or "\x00")
                             and vi.get("OriginalFilename", "") == a.exe,
                             "exe-version",
                             f"FileVersion={vi.get('FileVersion')} OriginalFilename={vi.get('OriginalFilename')} "
                             f"Description={vi.get('FileDescription')}"))

        mt = [(os.path.getmtime(os.path.join(root, n)), os.path.relpath(os.path.join(root, n), a.repo))
              for d in SRC_DIRS if os.path.isdir(J(d))
              for root, _, ns in os.walk(J(d)) for n in ns]
        mt += [(os.path.getmtime(J(f)), f) for f in SRC_FILES if os.path.exists(J(f))]
        newest, src = max(mt, default=(0, "?"))
        stale = newest > built + 2
        results.append(check(not stale, "freshness",
                             f"app.so {hm(built)} vs newest source {hm(newest)} ({src})"
                             + ("  <- would ship a STALE build, rerun flutter build" if stale else "")))

    staged = J(a.staging.replace("/", os.sep))
    if not os.path.isdir(staged):
        results.append(check(False, "staging", f"missing {staged} - run build_installer.py first"))
    else:
        names = [os.path.relpath(os.path.join(rt, n), staged).replace("\\", "/")
                 for rt, _, ns in os.walk(staged) for n in ns]
        leak = [n for n in names if any(x in n.lower() for x in a.leak)]
        results.append(check(not leak, "staging",
                             f"{len(names)} files, {sum(os.path.getsize(os.path.join(rt, n)) for rt, _, ns in os.walk(staged) for n in ns) // 1048576} MB"
                             if not leak else f"RUNTIME DATA WOULD BE PACKAGED: {leak[:5]}"))

    pkgs = [os.path.join(d, a.pkg_tpl.format(version=version)) for d in a.delivery]
    found = [p for p in pkgs if os.path.exists(p)]
    if len(found) != len(pkgs):
        results.append(check(False, "packages",
                             f"{len(found)}/{len(pkgs)} delivery dirs have it; missing: "
                             + "; ".join(os.path.dirname(p) for p in pkgs if p not in found)))
    else:
        dig = {p: (os.path.getsize(p), md5(p)) for p in found}
        uniq = {v for v in dig.values()}
        size, digest = sorted(dig.values())[0]
        late = built > os.path.getmtime(found[0]) + 120
        results.append(check(len(uniq) == 1 and size <= a.max_mb * 1048576 and not late,
                             "packages",
                             f"{len(pkgs)} dirs identical, {size / 1048576:.1f} MB, md5={digest[:12]}, "
                             f"built {hm(os.path.getmtime(found[0]))}"
                             if len(uniq) == 1 else "DIVERGENT: "
                             + "; ".join(f"{os.path.basename(p) if False else os.path.dirname(p)}={s} {h[:12]}"
                                         for p, (s, h) in dig.items())))
        if len(uniq) == 1 and late:
            print("          ^ the build is newer than the package - rerun build_installer.py")

    print(f"\nSummary: {'PASS' if all(results) else 'FAIL'} ({sum(results)}/{len(results)})")
    return 0 if all(results) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"[error] FAIL  {type(e).__name__}: {e}")
        print("Summary: FAIL")
        sys.exit(1)
