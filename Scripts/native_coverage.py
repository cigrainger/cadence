# SPDX-FileCopyrightText: 2026 Cadence contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Collect native execution without mixing release and debug coverage mappings."""
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def file_hash(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def reset_unit_coverage(scratch):
    # SwiftPM can retain raw profiles between filtered runs. Remove coverage
    # artifacts, never build products, before asking it for a fresh full report.
    for folder in scratch.glob("**/codecov"):
        if folder.is_dir():
            require(not folder.is_symlink() and folder.resolve().is_relative_to(scratch.resolve()),
                    "Coverage output must stay inside the build cache")
            for path in folder.iterdir():
                if path.is_file() and (path.suffix in (".profraw", ".profdata") or path.name == "Cadence.json"):
                    path.unlink()


def check_diagnostics(path):
    text = path.read_text(errors="replace")
    require("warning:" not in text.lower() and "error:" not in text.lower(),
            f"LLVM reported a coverage problem; see {path}")


def source_files(document, root):
    roots = tuple(str((root / "Sources" / name).resolve()) + "/" for name in ("Cadence", "MusicCore"))
    names = [str(Path(item["filename"]).resolve()) for data in document["data"] for item in data["files"]]
    names = [name for name in names if name.startswith(roots)]
    require(len(names) == len(set(names)), "Coverage contains duplicate first-party files")
    return set(names)


def check_source_inventory(document, root):
    measured = source_files(document, root)
    expected = {str(path.resolve()) for module in ("Cadence", "MusicCore")
                for path in (root / "Sources" / module).rglob("*.swift")}
    missing = sorted(expected - measured)
    require(not missing, "Coverage omitted first-party sources: " + ", ".join(missing))


@dataclass
class NativeCoverage:
    folder: Path
    executable: Path
    objects: tuple
    hashes: dict
    started: float

    @classmethod
    def prepare(cls, root, output, coverage_export, release_app, env, run):
        products = coverage_export.parent.parent
        debug = products / "Cadence"
        unit_profile = coverage_export.with_name("default.profdata")
        tests = sorted(path for path in products.glob("*.xctest/Contents/MacOS/*")
                       if path.is_file() and os.access(path, os.X_OK))
        require(debug.is_file() and unit_profile.is_file() and tests,
                "Missing instrumented app, XCTest objects or unit-test profile")
        folder = output / "native-coverage" / str(uuid.uuid4())
        folder.mkdir(parents=True)
        app = folder / "Cadence.app"
        shutil.copytree(release_app, app)
        executable = app / "Contents/MacOS/Cadence"
        shutil.copy2(debug, executable)
        objects_folder = folder / "objects"
        objects_folder.mkdir()
        objects = [executable]
        for index, path in enumerate(tests):
            destination = objects_folder / f"{index}-{path.name}"
            shutil.copy2(path, destination)
            objects.append(destination)
        shutil.copy2(unit_profile, folder / "unit.profdata")
        shutil.copy2(coverage_export, folder / "unit.json")
        run([sys.executable, root / "Scripts/signing.py", "--app", app, "--identity", "-"],
            folder / "signature.log", env, 30)
        hashes = {str(path): file_hash(path) for path in [*objects, folder / "unit.profdata", folder / "unit.json"]}
        (folder / "raw").mkdir()
        result = cls(folder, executable, tuple(objects), hashes, time.time())
        (folder / "manifest.json").write_text(json.dumps({
            "configuration": "debug-instrumented", "artifactsSHA256": hashes,
            "startedAtUnix": result.started,
        }, indent=2) + "\n")
        return result

    def environment(self, env):
        return dict(env, LLVM_PROFILE_FILE=str(self.folder / "raw/native-%p-%m.profraw"))

    def profiles(self, minimum):
        require(minimum > 0, "A native coverage run must execute at least one process")
        require(all(Path(path).is_file() and file_hash(Path(path)) == expected for path, expected in self.hashes.items()),
                "An instrumented coverage object or unit profile changed during the run")
        paths = sorted((self.folder / "raw").glob("*.profraw"))
        require(len(paths) >= minimum, f"Missing native profiles: expected at least {minimum}, received {len(paths)}")
        require(all(path.stat().st_size > 0 and path.stat().st_mtime >= self.started for path in paths),
                "A native coverage profile is empty or stale")
        return paths

    def finish(self, root, env, run, minimum):
        paths = self.profiles(minimum)
        merged = self.folder / "combined.profdata"
        log = self.folder / "merge.log"
        run(["xcrun", "llvm-profdata", "merge", "-sparse", self.folder / "unit.profdata", *paths, "-o", merged],
            log, env, 60)
        check_diagnostics(log)
        objects = [argument for path in self.objects[1:] for argument in ("-object", path)]
        export = self.folder / "combined.json"
        run(["xcrun", "llvm-cov", "export", self.executable, *objects, "-instr-profile", merged], export, env, 60)
        check_diagnostics(export)
        document = json.loads(export.read_text())
        check_source_inventory(document, root)
        unit = json.loads((self.folder / "unit.json").read_text())
        require(source_files(unit, root) <= source_files(document, root), "Native coverage lost unit-covered sources")
        # Use only actual first-party paths. Dependencies/tests remain in the raw
        # export for diagnosis, but do not inflate the application's denominator.
        run(["xcrun", "llvm-cov", "show", self.executable, *objects, "-instr-profile", merged,
             "-format=html", "-output-dir", self.folder / "html", *sorted(source_files(document, root))],
            self.folder / "html.log", env, 60)
        check_diagnostics(self.folder / "html.log")
        return document, {"configuration": "debug-instrumented", "profiles": len(paths),
                          "export": str(export), "html": str(self.folder / "html/index.html"),
                          "artifactsSHA256": self.hashes}
