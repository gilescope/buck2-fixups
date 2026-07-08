#!/usr/bin/env python3
"""Inject `size_bytes` into http_archive entries in generated BUCK files.

Why: buck2 defers a download entirely (never fetches on the driver; the
tarball is addressed in the CAS by digest) only when it can build the full
digest up front = sha256 + size. Without size_bytes it falls back to an HTTP
HEAD - and static.crates.io's CDN answers HEAD without Content-Length (and
ignores Range), so deferral silently fails and every fresh runner
re-downloads ~2k crates.io tarballs.

Sizes are learned once by downloading each crate (sha256-verified against
the declared checksum) and remembered in ci/crate-sizes.txt, so reruns and
reindeer regens are offline. Run after buckify: buckify-all.sh calls this.
"""

import concurrent.futures
import hashlib
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "ci" / "crate-sizes.txt"
BLOCK = re.compile(r"http_archive\(\n(?:    .*\n)+?\)", re.M)
ATTR = re.compile(r"    (sha256|size_bytes|urls) = (.+),\n")


def load_cache() -> dict[str, int]:
    if not CACHE.exists():
        return {}
    return {
        sha: int(size)
        for sha, size in (
            line.split() for line in CACHE.read_text().splitlines() if line.strip()
        )
    }


def fetch_size(url: str, want_sha: str) -> int:
    h = hashlib.sha256()
    n = 0
    with urllib.request.urlopen(url, timeout=60) as r:
        while chunk := r.read(1 << 16):
            h.update(chunk)
            n += len(chunk)
    if h.hexdigest() != want_sha:
        raise ValueError(
            f"{url}: sha256 mismatch (declared {want_sha}, got {h.hexdigest()})"
        )
    return n


def main() -> int:
    cache = load_cache()
    buck_files = (
        [ROOT / "third-party" / "BUCK"]
        + sorted((ROOT / "third-party" / "conflict-rigs").glob("*/BUCK"))
        + sorted((ROOT / "third-party" / "snapshots").glob("*/BUCK"))
    )

    # Pass 1: collect entries missing size_bytes.
    todo: dict[str, str] = {}  # sha256 -> url
    for bf in buck_files:
        for block in BLOCK.findall(bf.read_text()):
            attrs = dict((k, v) for k, v in ATTR.findall(block))
            if "sha256" in attrs and "size_bytes" not in attrs:
                sha = attrs["sha256"].strip('"')
                if sha not in cache:
                    url = re.search(r'"([^"]+)"', attrs.get("urls", "")).group(1)
                    todo[sha] = url

    if todo:
        print(f"fetching {len(todo)} crate sizes (sha256-verified) ...", flush=True)
        with concurrent.futures.ThreadPoolExecutor(24) as ex:
            futs = {ex.submit(fetch_size, url, sha): sha for sha, url in todo.items()}
            for i, fut in enumerate(concurrent.futures.as_completed(futs), 1):
                sha = futs[fut]
                cache[sha] = fut.result()  # raises on mismatch - fail loud
                if i % 200 == 0:
                    print(f"  {i}/{len(todo)}", flush=True)
        CACHE.write_text("".join(f"{s} {n}\n" for s, n in sorted(cache.items())))

    # Pass 2: rewrite blocks (idempotent; size_bytes sorts after sha256).
    changed = 0
    for bf in buck_files:
        text = bf.read_text()

        def inject(m: re.Match) -> str:
            nonlocal changed
            block = m.group(0)
            if "size_bytes" in block:
                return block
            sha_m = re.search(r'    sha256 = "([0-9a-f]{64})",\n', block)
            if not sha_m or sha_m.group(1) not in cache:
                return block
            changed += 1
            return block.replace(
                sha_m.group(0),
                sha_m.group(0) + f"    size_bytes = {cache[sha_m.group(1)]},\n",
            )

        new = BLOCK.sub(inject, text)
        if new != text:
            bf.write_text(new)

    print(f"size_bytes injected into {changed} http_archive entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
