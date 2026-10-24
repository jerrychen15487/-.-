"""Bind successful local IDF builds to their firmware inputs and flash artifacts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

RECEIPT = "build-receipt.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def firmware_inputs(project):
    paths = {project / "CMakeLists.txt", project / "dependencies.lock",
             project / "tools/build.ps1", project / "tools/build_receipt.py"}
    paths.update(p for p in (project / "main").rglob("*") if p.is_file())
    paths.update(project.glob("sdkconfig*.defaults"))
    paths.update(project.glob("*.csv"))
    # Include the installed, locked component sources: local edits also require a rebuild.
    paths.update(p for p in (project / "managed_components").rglob("*")
                 if p.is_file() and (p.suffix in (".c", ".h", ".S", ".cmake", ".yml")
                                    or p.name in ("CMakeLists.txt", "Kconfig", "Kconfig.projbuild")))
    return {p.relative_to(project).as_posix(): digest(p) for p in sorted(paths)}


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(build, receipt):
    (build / RECEIPT).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")


def begin(project, build):
    # Invalidate the previous success BEFORE configuration or any build artifact changes.
    write(build, {"version": 1, "state": "building", "inputs": firmware_inputs(project)})


def artifact_paths(build):
    flash = read(build / "flasher_args.json")
    desc = read(build / "project_description.json")
    paths = {"flasher_args.json", "flash_args", "project_description.json", desc["app_elf"],
             "config/sdkconfig.json", "config/sdkconfig.h", "config/sdkconfig.cmake"}
    paths.update(flash["flash_files"].values())
    for name in paths:
        (build / name).resolve().relative_to(build.resolve())
    return sorted(paths)


def verify_generated_config(config, build):
    values = {}
    deprecated = False
    for line in config.read_text(encoding="utf-8").splitlines():
        if line == "# Deprecated options for backward compatibility":
            deprecated = True
        elif line == "# End of deprecated options":
            deprecated = False
        elif not deprecated:
            match = re.fullmatch(r"CONFIG_(\w+)=(.*)", line)
            if match:
                key, value = match.groups()
                if value in ("y", "n"):
                    value = value == "y"
                elif value.startswith('"'):
                    value = json.loads(value)
                else:
                    value = int(value, 16 if value.startswith("0x") else 10)
                values[key] = value
            match = re.fullmatch(r"# CONFIG_(\w+) is not set", line)
            if match:
                values[match[1]] = False
    generated = read(build / "config/sdkconfig.json")
    if values != generated:
        raise ValueError("sdkconfig differs from the configuration generated for compilation; rebuild")


def finish(project, build, source_commit):
    receipt = read(build / RECEIPT)
    if receipt["state"] != "building" or receipt["inputs"] != firmware_inputs(project):
        raise ValueError("Firmware inputs changed during build; rebuild before packaging")
    desc = read(build / "project_description.json")
    if Path(desc["project_path"]).resolve() != project.resolve():
        raise ValueError("IDF build belongs to a different project")
    config = Path(desc["config_file"]).resolve()
    verify_generated_config(config, build)
    receipt.update(state="complete", completed_utc=datetime.now(timezone.utc).isoformat(),
                   source_commit=source_commit,
                   score_diagnostics=bool(read(build / "config/sdkconfig.json").get("SCORE_DIAGNOSTICS", False)),
                   config={"path": config.relative_to(project.resolve()).as_posix(), "sha256": digest(config)},
                   artifacts={name: digest(build / name) for name in artifact_paths(build)},
                   toolchain={key: desc[key] for key in ("idf_path", "git_revision", "c_compiler", "target")})
    write(build, receipt)


def verify(project, build):
    receipt = read(build / RECEIPT)
    if receipt.get("version") != 1 or receipt.get("state") != "complete":
        raise ValueError(f"{build.name}: no successful build receipt; run tools/build.ps1")
    if receipt["inputs"] != firmware_inputs(project):
        raise ValueError(f"{build.name}: firmware inputs differ from the successful build")
    config = (project / receipt["config"]["path"]).resolve()
    config.relative_to(project.resolve())
    if digest(config) != receipt["config"]["sha256"]:
        raise ValueError(f"{build.name}: sdkconfig changed after the successful build")
    if set(receipt["artifacts"]) != set(artifact_paths(build)):
        raise ValueError(f"{build.name}: flash artifact list changed after the successful build")
    for name, expected in receipt["artifacts"].items():
        if digest(build / name) != expected:
            raise ValueError(f"{build.name}: build artifact changed: {name}")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("begin", "finish"))
    parser.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    build = args.build.resolve()
    if build.parent != project or not build.name.startswith("build-"):
        raise ValueError("build must be an immediate trans/build-* directory")
    if args.action == "begin":
        begin(project, build)
    else:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project, text=True).strip()
        finish(project, build, commit)


if __name__ == "__main__":
    main()
