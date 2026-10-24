"""Collect complete IDF flash images and hashes. Never builds or opens hardware."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
from build_receipt import RECEIPT, digest, verify

from project_paths import PROJECT as TRANS, WEBSITE
ROOT = TRANS


def git(*args, cwd=ROOT):
    return subprocess.check_output(["git", *args], cwd=cwd, text=True, encoding="utf-8").strip()


def copy(source, target, expected=None):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    details = {"bytes": target.stat().st_size, "sha256": digest(target)}
    if expected is not None and details["sha256"] != expected:
        raise ValueError(f"Build changed during packaging: {source}; no valid release manifest produced")
    return details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="new directory beneath trans/build-*")
    parser.add_argument("--build", action="append", required=True, help="completed build directory name")
    args = parser.parse_args()
    output = (TRANS / args.output).resolve()
    relative = output.relative_to(TRANS)
    if len(relative.parts) != 1 or not relative.name.startswith("build-"):
        raise ValueError("release output must be a new trans/build-* directory")
    builds = []
    for name in args.build:
        build = (TRANS / name).resolve()
        if build.parent != TRANS or not build.name.startswith("build-"):
            raise ValueError("build must be an immediate trans/build-* directory")
        builds.append((name, build, verify(TRANS, build)))
    # Verify every build before creating output; never label stale binaries with current sources.
    # Refuse overwrite: previous acceptance evidence must remain independently identifiable.
    output.mkdir(exist_ok=False)
    manifest = {"created_utc": datetime.now(timezone.utc).isoformat(), "source_commit": git("rev-parse", "HEAD"),
                "status": "software release; all physical tests pending", "hardware_tested": False,
                "web_commit": git("rev-parse", "HEAD", cwd=WEBSITE),
                "images": [], "samples": [], "sources": {}}
    source_paths = git("ls-files", "main", "tools", "tests", "sdkconfig*", "dependencies.lock").splitlines()
    for name in source_paths:
        manifest["sources"][name] = digest(ROOT / name)
    for name, build, receipt in builds:
        flash = json.loads((build / "flasher_args.json").read_text(encoding="utf-8"))
        desc = json.loads((build / "project_description.json").read_text(encoding="utf-8"))
        config = Path(desc["config_file"])
        files = {}
        for offset, filename in flash["flash_files"].items():
            source = (build / filename).resolve()
            source.relative_to(build)
            files[offset] = {"file": filename, **copy(source, output / name / filename, receipt["artifacts"][filename])}
        copy(config, output / name / "sdkconfig", receipt["config"]["sha256"])
        for artifact in ("flasher_args.json", "flash_args"):
            copy(build / artifact, output / name / artifact, receipt["artifacts"][artifact])
        # Write the validated snapshot, not a receipt concurrently overwritten by another build.
        (output / name / RECEIPT).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        cfg = {}
        for line in (output / name / "sdkconfig").read_text(encoding="utf-8").splitlines():
            if line.startswith("CONFIG_") and "=" in line:
                key, value = line.split("=", 1)
                if key.startswith(("CONFIG_SCORE_", "CONFIG_BRIDGE_", "CONFIG_BT_NIMBLE_PINNED", "CONFIG_BT_CTRL_PINNED")):
                    cfg[key] = value
        manifest["images"].append({"build": name, "app_version": desc["project_version"],
                                   "build_source_commit": receipt["source_commit"],
                                   "build_receipt_sha256": digest(output / name / RECEIPT),
                                   "config": cfg, "flash_files": files,
                                   "uart_pins_confirmed": False})
        command = "& 'C:\\Espressif\\tools\\python\\v6.1\\venv\\Scripts\\python.exe' -m esptool --chip esp32s3 -p $boardPort -b 115200 --before default-reset --after hard-reset write-flash '@flash_args'"
        (output / name / "FLASH_COMMAND.txt").write_text(
            "Run only after checking GPIO/configuration and CH340 port. UART pins may be unassigned.\n"
            "Set-Location to THIS image directory first. Set $boardPort to the verified port (last known COM13).\n"
            + command + "\nApplication is NOT written at offset 0; flash_args contains all IDF-generated addresses.\n",
            encoding="utf-8")
    sample_manifest = WEBSITE / "tests/fixtures/handoff-packages.json"
    for entry in json.loads(sample_manifest.read_text(encoding="utf-8")):
        source = WEBSITE / entry["file"]
        target = output / "samples" / source.name
        details = copy(source, target)
        if details["sha256"] != entry["sha256"] or details["bytes"] != entry["bytes"]:
            raise ValueError(f"sample manifest differs: {entry['file']}")
        manifest["samples"].append({"file": "samples/" + source.name, "id": entry["id"],
                                    "crc32": entry["crc32"], "blocks": entry["blocks"],
                                    "tail_bytes": entry["tail_bytes"], **details})
    copy(sample_manifest, output / "samples/handoff-packages.json")
    manifest["psc2_parser_sha256"] = digest(WEBSITE / "src/lib/psc2.ts")
    for name in ("SCORE_TESTING.md", "SCORE_RESULT_TEMPLATE.md", "LATENCY_ACCEPTANCE.md", "VALIDATION.md", "PROTOCOL.md"):
        copy(TRANS / name, output / name)
    for source in (TRANS / "tools/score_pc").glob("*"):
        if source.is_file():
            copy(source, output / "tools/score_pc" / source.name)
    for name in ("score_pc.py", "validate_psc2.ts", "project_paths.py"):
        copy(TRANS / "tools" / name, output / "tools" / name)
    (output / "README.txt").write_text(
        "Local acceptance bundle. No physical tests have passed by creating this folder.\n"
        "SCORE_TESTING.md describes the order, wiring and commands. Rebuild UART images after confirming GPIO.\n"
        "Run PC tools from the V2.0 checkout: the PSC2 adapter intentionally depends on the adjacent website parser and Node/tsx.\n"
        "Copied tools are a source snapshot, not a standalone replacement for that dependency.\n"
        "manifest.json records source hashes, image hashes, configuration and sample provenance.\n", encoding="utf-8")
    for _, build, receipt in builds:
        if verify(TRANS, build) != receipt:
            raise ValueError("Build restarted during packaging; no valid release manifest produced")
    if any(digest(ROOT / name) != expected for name, expected in manifest["sources"].items()):
        raise ValueError("Tool or test sources changed during packaging; retry with a new output directory")
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Created {output}: {len(manifest['images'])} complete image sets, {len(manifest['samples'])} samples; physical tests pending")


if __name__ == "__main__":
    main()
