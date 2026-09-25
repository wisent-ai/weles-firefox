"""Package an existing Firefox build without launching or modifying it."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def command(argv, *, cwd=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} failed ({result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def package(app, version, output):
    if platform.system() != "Darwin":
        raise RuntimeError("Apple-signed Firefox packaging requires macOS")
    architecture = {"arm64": "darwin-arm64", "x86_64": "darwin-x64"}.get(platform.machine())
    if architecture is None:
        raise RuntimeError(f"unsupported macOS architecture: {platform.machine()}")
    capabilities = ROOT / "browser-capabilities.json"
    declared = json.loads(capabilities.read_text())
    upstream = declared["upstreamVersion"]
    if not re.fullmatch(re.escape(upstream) + r"-weles\.[1-9][0-9]*", version):
        raise RuntimeError(f"version must be {upstream}-weles.N with N greater than zero")
    app = app.expanduser().resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleExecutable") != "firefox" or info.get("CFBundleShortVersionString") != upstream:
        raise RuntimeError(f"input must be a Firefox {upstream} application")
    identifier = info.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", identifier):
        raise RuntimeError("Firefox application has no valid CFBundleIdentifier")
    executable = app / "Contents/MacOS/firefox"
    input_digest = digest(executable)
    revision = command(["git", "rev-parse", "HEAD"], cwd=ROOT)
    if command(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT):
        raise RuntimeError("commit Firefox packaging inputs before creating a candidate")
    patch_tree = command(["git", "rev-parse", "HEAD:patches"], cwd=ROOT)
    candidate = f"candidate-firefox-{version}-{revision[:8]}"
    output = output.expanduser().resolve()
    destination = output / f"{candidate}-{architecture}"
    if destination.exists():
        raise RuntimeError(f"candidate output already exists: {destination}")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".candidate-", dir=output) as directory:
        work = Path(directory)
        staged = work / "Firefox.app"
        shutil.copytree(app, staged, symlinks=True)
        signing = json.loads(command([
            "stado", "product", "signing", "sign", "--identifier", identifier,
            str(staged), "--json",
        ]))[0]
        if signing["state"] != "stable":
            raise RuntimeError(f"Firefox signature is not stable: {signing}")
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=anchor apple generic", str(staged)])
        published = work / "published"
        published.mkdir()
        archive = published / f"weles-firefox-{version}-{architecture}.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(staged, arcname="Firefox.app")
        archive_digest = digest(archive)
        (published / f"{archive.name}.sha256").write_text(f"{archive_digest}  {archive.name}\n")
        metadata = {
            "schema": "weles.browser-candidate.v1", "engine": "firefox",
            "finalTag": f"firefox-{version}", "candidateTag": candidate,
            "sourceRevision": revision, "patchTree": patch_tree, "platform": architecture,
            "entrypoint": "Firefox.app/Contents/MacOS/firefox", "artifact": archive.name,
            "artifactSha256": archive_digest, "capabilitiesSha256": digest(capabilities),
            "status": "candidate", "inputExecutableSha256": input_digest,
            "codeSignature": {key: signing[key] for key in ("identifier", "team", "authority", "requirement")},
        }
        (published / "release-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        shutil.copy2(capabilities, published / "browser-capabilities.release.json")
        if destination.exists():
            raise RuntimeError(f"candidate output already exists: {destination}")
        published.rename(destination)
    return {"directory": str(destination), **metadata}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="command", required=True)
    packaging = actions.add_parser("package", help="sign a copied Firefox app before archiving and hashing")
    packaging.add_argument("--app", type=Path, required=True)
    packaging.add_argument("--version", required=True)
    packaging.add_argument("--output", type=Path, default=ROOT / "artifacts")
    args = parser.parse_args()
    try:
        print(json.dumps(package(args.app, args.version, args.output), indent=2))
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
