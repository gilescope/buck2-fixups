#!/usr/bin/env bash
# Local tests for ci/add-archive-sizes.py - no network, no buck2.
#   ci/add-archive-sizes-test.sh
# Guards the two platform-default text-IO traps: the script must not
# inherit the locale's encoding (cp1252 on windows runners) and must not
# inherit the platform's newline translation (CRLF on windows), or a
# BUCK file round-trips differently per OS and --check reports a clean
# tree as dirty.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

# ── the fixture reproduces the windows failure under cp1252 ─────────
# Byte 0x81 is undefined in cp1252 - exactly the byte that killed
# buckify-all.sh --check on win x86 (position 358555 of third-party/BUCK).
printf 'http_archive(\n    name = "x",\n    sha256 = "%s",\n    urls = ["u"],\n)\n# caf\xc3\xa9 \xc2\x81\n' \
  "$(printf 'a%.0s' $(seq 64))" > "$T/BUCK"
# iconv, not python: the test should not depend on the interpreter whose
# default encoding is the thing under test.
if iconv -f CP1252 -t UTF-8 < "$T/BUCK" > /dev/null 2>&1; then
  fail "fixture does not reproduce the cp1252 decode failure"
fi
ok "fixture: 0x81 is undecodable as cp1252 (the windows default)"

# ── every text IO call names its encoding ───────────────────────────
# A bare read_text()/write_text() takes locale.getpreferredencoding(),
# which is why this was green on linux and mac for months.
calls=$(grep -nE '\b(read|write)_text\(' ci/add-archive-sizes.py \
  | grep -v '^[0-9]*:#' || true)
bare=$(printf '%s\n' "$calls" | grep -vE 'encoding=|\*\*UTF8' || true)
[ -z "$bare" ] || fail "unencoded text IO: $bare"
ok "no bare read_text/write_text - encoding is explicit everywhere"

# ── writes pin the newline, so the output is byte-identical per OS ──
writes=$(printf '%s\n' "$calls" | grep -c 'write_text(' || true)
pinned=$(printf '%s\n' "$calls" | grep 'write_text(' \
  | grep -cE 'UTF8_OUT|newline=' || true)
[ "$writes" -gt 0 ] || fail "no write_text calls found - test is looking at the wrong file"
[ "$writes" -eq "$pinned" ] \
  || fail "$writes write_text calls but only $pinned pin the newline"
grep -q 'UTF8_OUT = {"encoding": "utf-8", "newline": "\\n"}' \
  ci/add-archive-sizes.py || fail "UTF8_OUT does not pin utf-8 + LF"
ok "every write pins newline (no CRLF translation on windows)"

# ── round-trip through the REAL write path ──────────────────────────
# Seed the size cache so no fetch is attempted, then let the script
# rewrite the block: this is the path that read the file as cp1252 on
# windows and would write it back with CRLF.
SHA=$(printf 'a%.0s' $(seq 64))
mkdir -p "$T/root/third-party" "$T/root/ci"
cp "$T/BUCK" "$T/root/third-party/BUCK"
echo "$SHA 12345" > "$T/root/ci/crate-sizes.txt"
cp ci/add-archive-sizes.py "$T/root/ci/"
( cd "$T/root" && python3 ci/add-archive-sizes.py > /dev/null ) \
  || fail "script failed on a UTF-8 BUCK file"
grep -q "size_bytes = 12345," "$T/root/third-party/BUCK" \
  || fail "size_bytes was not injected - the write path never ran"
if LC_ALL=C grep -q "$(printf '\r')" "$T/root/third-party/BUCK"; then
  fail "CRLF in output - newline not pinned"
fi
# The non-ASCII line must come back byte-identical.
tail -1 "$T/BUCK" > "$T/want-tail"
tail -1 "$T/root/third-party/BUCK" > "$T/got-tail"
cmp -s "$T/want-tail" "$T/got-tail" \
  || fail "non-ASCII content mangled through the round-trip"
iconv -f UTF-8 -t UTF-8 < "$T/root/third-party/BUCK" > /dev/null \
  || fail "output is not valid UTF-8"
ok "round-trip: injects, keeps UTF-8 bytes, writes LF only"

echo "PASS: $pass groups"
