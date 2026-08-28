#!/usr/bin/env python3
"""Validate an ALARM repository snapshot and record installed package provenance."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import pathlib
import re
import subprocess
import sys
import tarfile


REPOSITORIES = ("core", "extra", "alarm", "aur")
FORMAT = "alarm-repository-snapshot-v1"
SHA256 = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_id(records: dict[str, tuple[str, int]]) -> str:
    canonical = "".join(
        f"repo\t{repository}\t{records[repository][0]}\t{records[repository][1]}\n"
        for repository in REPOSITORIES
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def load_manifest(path: pathlib.Path) -> tuple[dict[str, str], dict[str, tuple[str, int]]]:
    metadata: dict[str, str] = {}
    records: dict[str, tuple[str, int]] = {}
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if fields[0] == "repo":
            if len(fields) != 4 or fields[1] not in REPOSITORIES:
                fail(f"invalid repository record at {path}:{number}")
            if fields[1] in records or not SHA256.fullmatch(fields[2]):
                fail(f"duplicate or invalid repository record at {path}:{number}")
            try:
                size = int(fields[3])
            except ValueError:
                fail(f"invalid repository size at {path}:{number}")
            if size <= 0:
                fail(f"invalid repository size at {path}:{number}")
            records[fields[1]] = (fields[2], size)
        else:
            if len(fields) != 2 or fields[0] in metadata:
                fail(f"duplicate or invalid metadata at {path}:{number}")
            metadata[fields[0]] = fields[1]

    required = {
        "format",
        "architecture",
        "primary-url",
        "secondary-url",
        "sync-marker",
        "captured-at",
        "snapshot-id",
    }
    if set(metadata) != required:
        fail(f"snapshot metadata fields do not match {sorted(required)}")
    if metadata["format"] != FORMAT or metadata["architecture"] != "aarch64":
        fail("unsupported repository snapshot format or architecture")
    if not metadata["primary-url"].startswith("https://") or not metadata[
        "secondary-url"
    ].startswith("https://"):
        fail("repository snapshot sources must use HTTPS")
    if metadata["primary-url"] == metadata["secondary-url"]:
        fail("repository snapshot requires two distinct official mirrors")
    if not metadata["sync-marker"].isdigit():
        fail("invalid repository snapshot sync marker")
    if set(records) != set(REPOSITORIES):
        fail(f"snapshot repositories do not match {list(REPOSITORIES)}")
    expected_id = snapshot_id(records)
    if metadata["snapshot-id"] != expected_id:
        fail("repository snapshot ID does not match its records")
    return metadata, records


def validate(snapshot_dir: pathlib.Path, manifest: pathlib.Path) -> tuple[dict[str, str], dict[str, tuple[str, int]]]:
    metadata, records = load_manifest(manifest)
    actual_names = {path.name for path in snapshot_dir.glob("*.db")}
    expected_names = {f"{repository}.db" for repository in REPOSITORIES}
    if actual_names != expected_names:
        fail(f"snapshot database files do not match {sorted(expected_names)}")
    for repository in REPOSITORIES:
        path = snapshot_dir / f"{repository}.db"
        expected_hash, expected_size = records[repository]
        if path.stat().st_size != expected_size:
            fail(f"{repository}.db size does not match the snapshot manifest")
        if file_sha256(path) != expected_hash:
            fail(f"{repository}.db SHA-256 does not match the snapshot manifest")
        try:
            with tarfile.open(path, "r:*") as archive:
                next((member for member in archive if member.name.endswith("/desc")))
        except (tarfile.TarError, StopIteration):
            fail(f"{repository}.db is not a usable pacman repository database")
    return metadata, records


def write_manifest(args: argparse.Namespace) -> None:
    snapshot_dir = pathlib.Path(args.snapshot_dir)
    records = {
        repository: (
            file_sha256(snapshot_dir / f"{repository}.db"),
            (snapshot_dir / f"{repository}.db").stat().st_size,
        )
        for repository in REPOSITORIES
    }
    lines = [
        f"format\t{FORMAT}",
        "architecture\taarch64",
        f"primary-url\t{args.primary_url}",
        f"secondary-url\t{args.secondary_url}",
        f"sync-marker\t{args.sync_marker}",
        f"captured-at\t{args.captured_at}",
        f"snapshot-id\t{snapshot_id(records)}",
    ]
    lines.extend(
        f"repo\t{repository}\t{records[repository][0]}\t{records[repository][1]}"
        for repository in REPOSITORIES
    )
    pathlib.Path(args.manifest).write_text("\n".join(lines) + "\n")


def parse_desc(raw: bytes) -> dict[str, list[str]]:
    fields: dict[str, list[str]] = {}
    key: str | None = None
    for line in raw.decode("utf-8", "strict").splitlines():
        if len(line) >= 3 and line.startswith("%") and line.endswith("%"):
            key = line[1:-1]
            fields.setdefault(key, [])
        elif line and key is not None:
            fields[key].append(line)
    return fields


def one(fields: dict[str, list[str]], key: str) -> str:
    values = fields.get(key, [])
    if len(values) != 1:
        fail(f"repository record has no unique %{key}% field")
    return values[0]


def repository_packages(snapshot_dir: pathlib.Path) -> dict[tuple[str, str, str], list[dict[str, str]]]:
    packages: dict[tuple[str, str, str], list[dict[str, str]]] = {}
    for repository in REPOSITORIES:
        with tarfile.open(snapshot_dir / f"{repository}.db", "r:*") as archive:
            for member in archive:
                if not member.isfile() or not member.name.endswith("/desc"):
                    continue
                source = archive.extractfile(member)
                if source is None:
                    continue
                try:
                    fields = parse_desc(source.read())
                except UnicodeDecodeError:
                    continue
                if "NAME" not in fields:
                    continue
                name, version = one(fields, "NAME"), one(fields, "VERSION")
                package_hash = one(fields, "SHA256SUM")
                signature = one(fields, "PGPSIG")
                if not SHA256.fullmatch(package_hash):
                    fail(f"invalid package SHA-256 for {repository}/{name}")
                try:
                    signature_bytes = base64.b64decode(signature, validate=True)
                except (ValueError, binascii.Error):
                    fail(f"invalid package PGP signature for {repository}/{name}")
                architecture = one(fields, "ARCH")
                key = (name, version, architecture)
                packages.setdefault(key, []).append(
                    {
                        "repository": repository,
                        "filename": one(fields, "FILENAME"),
                        "package-sha256": package_hash,
                        "signature-sha256": hashlib.sha256(signature_bytes).hexdigest(),
                    }
                )
    return packages


def installed_packages(local_db: pathlib.Path) -> list[tuple[str, str, str, pathlib.Path]]:
    installed: list[tuple[str, str, str, pathlib.Path]] = []
    for desc in local_db.glob("*/desc"):
        fields = parse_desc(desc.read_bytes())
        if "NAME" not in fields:
            continue
        installed.append(
            (one(fields, "NAME"), one(fields, "VERSION"), one(fields, "ARCH"), desc.parent)
        )
    if not installed:
        fail(f"no installed packages found under {local_db}")
    return sorted(installed)


def cached_package_mtree(
    cache_dir: pathlib.Path, local_record: pathlib.Path, record: dict[str, str]
) -> str | None:
    package = cache_dir / record["filename"]
    local_mtree = local_record / "mtree"
    if not package.is_file() or not local_mtree.is_file():
        return None
    if file_sha256(package) != record["package-sha256"]:
        return None
    extracted = subprocess.run(
        ["bsdtar", "-xOf", str(package), ".MTREE"],
        capture_output=True,
        check=False,
    )
    if extracted.returncode != 0 or extracted.stdout != local_mtree.read_bytes():
        return None
    return hashlib.sha256(extracted.stdout).hexdigest()


HEADER = (
    "snapshot-id\tevidence\trepository-candidate\tname\tversion\tarchitecture\t"
    "filename\tpackage-sha256\tpgp-signature-sha256\tinstalled-mtree-sha256"
)


def provenance_lines(
    snapshot_dir: pathlib.Path,
    manifest: pathlib.Path,
    local_db: pathlib.Path,
    cache_dir: pathlib.Path,
) -> list[str]:
    metadata, _ = validate(snapshot_dir, manifest)
    available = repository_packages(snapshot_dir)
    lines = [HEADER]
    for name, version, architecture, local_record in installed_packages(local_db):
        records = available.get((name, version, architecture), [])
        if not records:
            values = (
                metadata["snapshot-id"], "local-or-unknown", "-", name, version,
                architecture, "-", "-", "-", "-",
            )
        elif len(records) > 1:
            candidates = ",".join(record["repository"] for record in records)
            values = (
                metadata["snapshot-id"], "ambiguous-snapshot-match", candidates,
                name, version, architecture, "-", "-", "-", "-",
            )
        else:
            record = records[0]
            mtree_hash = cached_package_mtree(cache_dir, local_record, record)
            evidence = "repository-cache+mtree" if mtree_hash else "snapshot-metadata-only"
            values = (
                metadata["snapshot-id"],
                evidence,
                record["repository"],
                name,
                version,
                architecture,
                record["filename"],
                record["package-sha256"],
                record["signature-sha256"],
                mtree_hash or "-",
            )
        lines.append("\t".join(values))
    return lines


def write_provenance(args: argparse.Namespace) -> None:
    snapshot_dir = pathlib.Path(args.snapshot_dir)
    lines = provenance_lines(
        snapshot_dir,
        pathlib.Path(args.manifest),
        pathlib.Path(args.local_db),
        pathlib.Path(args.cache_dir),
    )
    pathlib.Path(args.output).write_text("\n".join(lines) + "\n")


def validate_provenance(args: argparse.Namespace) -> None:
    snapshot_dir = pathlib.Path(args.snapshot_dir)
    metadata, _ = validate(snapshot_dir, pathlib.Path(args.manifest))
    available = repository_packages(snapshot_dir)
    installed = {
        (name, version, architecture): local_record
        for name, version, architecture, local_record in installed_packages(pathlib.Path(args.local_db))
    }
    rows = pathlib.Path(args.provenance).read_text().splitlines()
    if not rows or rows[0] != HEADER:
        fail("installed-package provenance header is invalid")
    seen: set[tuple[str, str, str]] = set()
    for number, row in enumerate(rows[1:], 2):
        fields = row.split("\t")
        if len(fields) != 10:
            fail(f"invalid installed-package provenance row {number}")
        snapshot, evidence, candidate, name, version, architecture, filename, package_hash, signature_hash, mtree_hash = fields
        key = (name, version, architecture)
        if snapshot != metadata["snapshot-id"] or key not in installed or key in seen:
            fail(f"wrong snapshot, unknown package, or duplicate provenance row {number}")
        seen.add(key)
        records = available.get(key, [])
        if not records:
            expected = ("local-or-unknown", "-", "-", "-", "-", "-")
        elif len(records) > 1:
            expected = (
                "ambiguous-snapshot-match",
                ",".join(record["repository"] for record in records),
                "-", "-", "-", "-",
            )
        else:
            record = records[0]
            if evidence not in {"repository-cache+mtree", "snapshot-metadata-only"}:
                fail(f"invalid repository evidence in provenance row {number}")
            expected = (
                evidence,
                record["repository"],
                record["filename"],
                record["package-sha256"],
                record["signature-sha256"],
                mtree_hash,
            )
            if evidence == "repository-cache+mtree":
                local_mtree = installed[key] / "mtree"
                if not SHA256.fullmatch(mtree_hash) or not local_mtree.is_file() \
                        or file_sha256(local_mtree) != mtree_hash:
                    fail(f"installed mtree evidence does not validate in provenance row {number}")
            elif mtree_hash != "-":
                fail(f"metadata-only provenance has mtree evidence in row {number}")
        actual = (evidence, candidate, filename, package_hash, signature_hash, mtree_hash)
        if actual != expected:
            fail(f"installed-package provenance fields do not validate in row {number}")
    if seen != set(installed):
        fail("installed-package provenance is incomplete")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    writer = subparsers.add_parser("write-manifest")
    writer.add_argument("snapshot_dir")
    writer.add_argument("manifest")
    writer.add_argument("primary_url")
    writer.add_argument("secondary_url")
    writer.add_argument("sync_marker")
    writer.add_argument("captured_at")
    writer.set_defaults(handler=write_manifest)

    checker = subparsers.add_parser("validate")
    checker.add_argument("snapshot_dir")
    checker.add_argument("manifest")
    checker.set_defaults(handler=lambda args: validate(pathlib.Path(args.snapshot_dir), pathlib.Path(args.manifest)))

    provenance = subparsers.add_parser("provenance")
    provenance.add_argument("snapshot_dir")
    provenance.add_argument("manifest")
    provenance.add_argument("output")
    provenance.add_argument("--local-db", default="/var/lib/pacman/local")
    provenance.add_argument("--cache-dir", default="/var/cache/pacman/pkg")
    provenance.set_defaults(handler=write_provenance)

    provenance_check = subparsers.add_parser("validate-provenance")
    provenance_check.add_argument("snapshot_dir")
    provenance_check.add_argument("manifest")
    provenance_check.add_argument("provenance")
    provenance_check.add_argument("--local-db", default="/var/lib/pacman/local")
    provenance_check.set_defaults(handler=validate_provenance)

    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
