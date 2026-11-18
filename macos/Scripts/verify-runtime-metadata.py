#!/usr/bin/env python3
"""Reject old VM artifacts and mismatched builder metadata before packaging."""
import hashlib
from pathlib import Path
import sys


def values(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            if key in result:
                raise ValueError(f"Duplicate metadata key: {key}")
            result[key] = value
    return result


artifact, metadata_path, expected_path = sys.argv[1:]
metadata = values(metadata_path)
expected = values(expected_path)
if metadata.get("SMOLVM_RUNTIME_FORMAT") != "embedded-buildkit-1":
    raise ValueError("SmolVM image does not contain the required embedded builder")
for key in ["DOCKER_VERSION", "BUILDX_VERSION", "BUILDKIT_VERSION", "BUILDKIT_IMAGE_ID"]:
    if metadata.get(key) != expected[key]:
        raise ValueError(f"SmolVM image differs from the launcher requirement: {key}")
digest = hashlib.sha256()
with open(artifact, "rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
if digest.hexdigest() != metadata["SMOLVM_COMPOSE_SHA256"]:
    raise ValueError("SmolVM artifact checksum differs from its builder metadata")
print("Verified embedded Docker/BuildKit image and artifact checksum")
