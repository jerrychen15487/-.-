"""Freeze/verify complete flash sets. No hardware is opened by any command."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
from build_receipt import digest, verify as verify_build
from project_paths import PROJECT


def inspect_build(build):
    receipt = verify_build(PROJECT, build)
    cfg = json.loads((build / "config/sdkconfig.json").read_text(encoding="utf-8"))
    profile = {key: cfg.get(key, False) for key in (
        "BRIDGE_SIM_INPUT", "BRIDGE_DETAIL_LOG", "BRIDGE_READY_BYPASS",
        "SCORE_ENABLED", "SCORE_BLE_ENABLED", "SCORE_DIAGNOSTICS", "SCORE_UART_SELF_TEST",
        "SCORE_UART_TX_PIN", "SCORE_UART_RX_PIN", "BT_NIMBLE_LOG_LEVEL")}
    return receipt, profile


def create(build, name):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
        raise ValueError("image name must contain lowercase letters, numbers and hyphens")
    receipt, profile = inspect_build(build)
    target = PROJECT / "images" / name
    target.mkdir(parents=True, exist_ok=False)
    flash = json.loads((build / "flasher_args.json").read_text(encoding="utf-8"))
    paths = set(flash["flash_files"].values()) | {"flash_args", "flasher_args.json", "build-receipt.json"}
    checksums = {}
    for filename in sorted(paths):
        source = (build / filename).resolve()
        source.relative_to(build.resolve())
        destination = target / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        checksums[filename] = digest(destination)
    shutil.copyfile(PROJECT / receipt["config"]["path"], target / "sdkconfig")
    checksums["sdkconfig"] = digest(target / "sdkconfig")
    if verify_build(PROJECT, build) != receipt:
        raise ValueError("build changed during image capture")
    info = {"version": "2.0", "image": name, "created_utc": datetime.now(timezone.utc).isoformat(),
            "source_commit": receipt["source_commit"], "build_directory": build.name,
            "hardware_tested": False, "profile": profile, "files": checksums,
            "flash_files": flash["flash_files"],
            "elf_sha256": receipt["artifacts"]["midi_spi_bridge.elf"]}
    (target / "image.json").write_text(json.dumps(info, indent=2)+"\n", encoding="utf-8")
    verify_image(target)
    return info


def verify_image(image):
    info = json.loads((image / "image.json").read_text(encoding="utf-8"))
    if info["version"] != "2.0":
        raise ValueError("not a V2.0 image manifest")
    for name, expected in info["files"].items():
        path = (image / name).resolve()
        path.relative_to(image.resolve())
        if digest(path) != expected:
            raise ValueError(f"image checksum mismatch: {name}")
    for name in info["flash_files"].values():
        if name not in info["files"]:
            raise ValueError(f"unverified flash file: {name}")
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("create"); p.add_argument("--build", type=Path, required=True); p.add_argument("--name", required=True)
    p = sub.add_parser("verify"); p.add_argument("--image", type=Path, required=True)
    p = sub.add_parser("check-build"); p.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "create":
        result = create(args.build.resolve(), args.name)
    elif args.action == "verify":
        result = verify_image(args.image.resolve())
    else:
        receipt, profile = inspect_build(args.build.resolve())
        result = {"source_commit": receipt["source_commit"], "profile": profile}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
