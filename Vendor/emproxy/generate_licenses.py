#!/usr/bin/env python3
"""Generate deterministic license notices for the locked iOS dependency tree."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "Cargo.toml"
TARGET = "aarch64-apple-ios"


def cargo(*arguments: str) -> str:
    return subprocess.run(
        ["cargo", *arguments, "--manifest-path", str(MANIFEST)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


tree = cargo(
    "tree",
    "--locked",
    "--target",
    TARGET,
    "--edges",
    "normal,build",
    "--prefix",
    "none",
    "--format",
    "{p}",
)
package_pattern = re.compile(r"^([A-Za-z0-9_-]+) v([^ ]+)")
linked = {
    match.groups()
    for line in tree.splitlines()
    if (match := package_pattern.match(line)) and match.group(1) != "aurora-emproxy"
}

metadata = json.loads(
    cargo("metadata", "--locked", "--format-version", "1", "--filter-platform", TARGET)
)
packages = {
    (package["name"], package["version"]): package for package in metadata["packages"]
}

documents: dict[str, str] = {}
document_uses: dict[str, list[str]] = defaultdict(list)
inventory: list[str] = []

for name, version in sorted(linked):
    package = packages[(name, version)]
    license_expression = package.get("license") or "NO SPDX EXPRESSION"
    inventory.append(f"{name} {version}: {license_expression}")
    source_dir = Path(package["manifest_path"]).parent
    candidates = {
        path
        for pattern in ("LICENSE*", "COPYING*", "COPYRIGHT*")
        for path in source_dir.glob(pattern)
        if path.is_file()
    }
    if package.get("license_file"):
        candidates.add(source_dir / package["license_file"])
    if name == "boringtun" and not candidates:
        candidates.add(ROOT / "LICENSE.boringtun.txt")
    if not candidates:
        raise RuntimeError(f"No license document found for {name} {version}")

    for path in sorted(candidates):
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        digest = hashlib.sha256(content.encode()).hexdigest()
        documents[digest] = content
        document_uses[digest].append(f"{name} {version}/{path.name}")

lines = [
    "Aurora EMProxy dependency license notices",
    "==========================================",
    "",
    f"Target: {TARGET}",
    "Dependency selection: Cargo.lock normal and build dependency tree",
    "",
    "Package inventory",
    "-----------------",
    *inventory,
    "",
    "License documents",
    "-----------------",
]
for digest in sorted(documents):
    lines.extend(
        [
            "",
            f"SHA-256: {digest}",
            "Used by:",
            *(f"- {usage}" for usage in sorted(document_uses[digest])),
            "",
            documents[digest],
        ]
    )

(ROOT / "LICENSES.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
