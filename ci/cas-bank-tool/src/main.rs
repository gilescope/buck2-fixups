//! CAS-bank helper: the fork-free hot paths of `ci/cas-bank.sh`.
//!
//! Shell loops fork per item and melt at fleet scale (run 29435672672:
//! 11 workers stalled 30min+); everything per-blob lives here instead.
//! Zero dependencies so `cargo build` works offline on every runner.
//!
//! Subcommands:
//!   index <store>               blob\tpath\tbytes for cas/xx/<hash>, blob-sorted
//!   ac-index <store>            path\tsha256\tbytes for ac/ + acn/ rows, path-sorted
//!   tar <store> <batch> <out>   deterministic USTAR of batch's store-relative paths
//!   link <store> <paths> <dst>  hardlink (copy fallback) paths into dst
//!   gen-store <dir> <n>         synthetic corpus: n blobs across all prefixes
//!   gen-ac <dir> <n>            synthetic corpus: n AC rows (flat ac/ + acn/xx/)
//!   gen-segments <dir> <n>      synthetic corpus: n segment dirs (meta + blobs.txt)

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let strs: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match strs.as_slice() {
        ["index", store] => index(Path::new(store)),
        ["ac-index", store] => ac_index(Path::new(store)),
        ["tar", store, batch, out] => tar(Path::new(store), Path::new(batch), Path::new(out)),
        ["link", store, paths, dst] => link(Path::new(store), Path::new(paths), Path::new(dst)),
        ["gen-store", dir, n] => gen_store(Path::new(dir), n.parse().unwrap_or(0)),
        ["gen-ac", dir, n] => gen_ac(Path::new(dir), n.parse().unwrap_or(0)),
        ["gen-segments", dir, n] => gen_segments(Path::new(dir), n.parse().unwrap_or(0)),
        ["ac-purge-failures", dir] => ac_purge_failures(Path::new(dir)),
        _ => {
            eprintln!(
                "usage: cas-bank-tool index <store> | tar <store> <batch> <out> \
                 | ac-index <store> | link <store> <paths> <dst> \
                 | gen-store <dir> <n> | gen-ac <dir> <n> \
                 | gen-segments <dir> <n> | ac-purge-failures <ac_dir>"
            );
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cas-bank-tool: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Print `blob\tcas/xx/blob\tbytes`, sorted by blob (byte-lexical, so
/// `comm`/`join` against C-sorted lists agree).
fn index(store: &Path) -> std::io::Result<()> {
    let cas = store.join("cas");
    let mut rows: BTreeMap<String, (String, u64)> = BTreeMap::new();
    if cas.is_dir() {
        for d in fs::read_dir(&cas)? {
            let d = d?;
            if !d.file_type()?.is_dir() {
                continue;
            }
            let dname = d.file_name().to_string_lossy().into_owned();
            for f in fs::read_dir(d.path())? {
                let f = f?;
                let meta = f.metadata()?;
                if !meta.is_file() {
                    continue;
                }
                let blob = f.file_name().to_string_lossy().into_owned();
                let rel = format!("cas/{dname}/{blob}");
                rows.insert(blob, (rel, meta.len()));
            }
        }
    }
    let mut w = BufWriter::new(std::io::stdout().lock());
    for (blob, (rel, size)) in rows {
        writeln!(w, "{blob}\t{rel}\t{size}")?;
    }
    w.flush()
}

/// FIPS 180-4 SHA-256, hex. Hand-rolled because this binary is
/// deliberately dependency-free (it must build offline on every runner),
/// and the AC bank's diff key is `(row name, sha256(content))` - rows are
/// name-stable but content-mutable, so the name alone cannot tell a
/// re-executed action's new result from its old one. Cross-checked
/// against sha256sum/shasum in ci/cas-bank-test.sh.
fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64) * 8;
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());

    let mut w = [0u32; 64];
    for block in msg.chunks_exact(64) {
        for (i, word) in w.iter_mut().take(16).enumerate() {
            *word = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d) = (h[0], h[1], h[2], h[3]);
        let (mut e, mut f, mut g, mut hh) = (h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (slot, v) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *slot = slot.wrapping_add(v);
        }
    }
    let mut out = String::with_capacity(64);
    for v in h {
        out.push_str(&format!("{v:08x}"));
    }
    out
}

/// Every AC row under `store`, as `path\tsha256\tbytes`, path-sorted.
///
/// Two layouts, both live: `ac/<digest>` is FLAT and `acn/<xx>/<key>` is
/// one level deep (store.rs). Paths are store-relative so the same lines
/// feed `tar`'s batch file directly.
fn ac_index(store: &Path) -> std::io::Result<()> {
    let mut rows: BTreeMap<String, (String, u64)> = BTreeMap::new();
    let mut visit = |dir: &Path, prefix: &str, depth: u32| -> std::io::Result<()> {
        if !dir.is_dir() {
            return Ok(());
        }
        for e in fs::read_dir(dir)? {
            let e = e?;
            let name = e.file_name().to_string_lossy().into_owned();
            let ft = e.file_type()?;
            if ft.is_dir() {
                if depth == 0 {
                    continue;
                }
                for f in fs::read_dir(e.path())? {
                    let f = f?;
                    if !f.file_type()?.is_file() {
                        continue;
                    }
                    let leaf = f.file_name().to_string_lossy().into_owned();
                    let bytes = fs::read(f.path())?;
                    rows.insert(
                        format!("{prefix}/{name}/{leaf}"),
                        (sha256_hex(&bytes), bytes.len() as u64),
                    );
                }
            } else if ft.is_file() {
                let bytes = fs::read(e.path())?;
                rows.insert(
                    format!("{prefix}/{name}"),
                    (sha256_hex(&bytes), bytes.len() as u64),
                );
            }
        }
        Ok(())
    };
    visit(&store.join("ac"), "ac", 0)?;
    visit(&store.join("acn"), "acn", 1)?;
    let mut w = BufWriter::new(std::io::stdout().lock());
    for (path, (hash, size)) in rows {
        writeln!(w, "{path}\t{hash}\t{size}")?;
    }
    w.flush()
}

/// Write one octal field: zero-padded to `width - 1`, NUL-terminated.
fn octal(field: &mut [u8], val: u64) {
    let s = format!("{:0width$o}", val, width = field.len() - 1);
    field[..s.len()].copy_from_slice(s.as_bytes());
    field[s.len()] = 0;
}

/// Deterministic USTAR: fixed mode 0755, uid/gid 0, mtime 0, empty
/// uname/gname, entries sorted by path. The segment NAME is the sha256
/// of this raw tar, so any nondeterminism here forks segment names for
/// identical content - hence 0755 for EVERYTHING rather than
/// preserving source modes (windows has none to preserve). Spurious
/// exec bits on data blobs are harmless; a MISSING exec bit is not:
/// rebuck2 hardlinks store files into exec dirs, so a 0644 build
/// script dies with EACCES (lap 29507595376, 29 targets).
fn tar(store: &Path, batch: &Path, out: &Path) -> std::io::Result<()> {
    let mut paths: Vec<String> = BufReader::new(fs::File::open(batch)?)
        .lines()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|l| !l.trim().is_empty())
        .collect();
    paths.sort();
    paths.dedup();

    let mut w = BufWriter::new(fs::File::create(out)?);
    let mut written: u64 = 0;
    for rel in &paths {
        let src = store.join(rel);
        let size = fs::metadata(&src)?.len();

        let mut h = [0u8; 512];
        h[..rel.len()].copy_from_slice(rel.as_bytes()); // cas/xx/<64hex> = 71 <= 100
        octal(&mut h[100..108], 0o755); // mode: see doc comment
        octal(&mut h[108..116], 0); // uid
        octal(&mut h[116..124], 0); // gid
        octal(&mut h[124..136], size);
        octal(&mut h[136..148], 0); // mtime
        h[148..156].copy_from_slice(b"        "); // chksum: spaces while summing
        h[156] = b'0'; // typeflag: regular file
        h[257..263].copy_from_slice(b"ustar\0");
        h[263..265].copy_from_slice(b"00");
        octal(&mut h[329..337], 0); // devmajor
        octal(&mut h[337..345], 0); // devminor
        let sum: u64 = h.iter().map(|&b| u64::from(b)).sum();
        let chk = format!("{sum:06o}\0 ");
        h[148..156].copy_from_slice(chk.as_bytes());
        w.write_all(&h)?;
        written += 512;

        let mut f = fs::File::open(&src)?;
        let copied = std::io::copy(&mut f, &mut w)?;
        if copied != size {
            return Err(std::io::Error::other(format!(
                "{rel}: changed size mid-pack ({size} -> {copied} bytes)"
            )));
        }
        written += copied;
        let pad = (512 - (copied % 512) % 512) % 512;
        w.write_all(&vec![0u8; pad as usize])?;
        written += pad;
    }
    // Two zero blocks, then pad to the conventional 10240 record size.
    w.write_all(&[0u8; 1024])?;
    written += 1024;
    let pad = (10240 - (written % 10240)) % 10240;
    w.write_all(&vec![0u8; pad as usize])?;
    w.flush()
}

/// Hardlink every store-relative path in `paths` into `dst` (copy when
/// linking fails, e.g. across filesystems).
fn link(store: &Path, paths: &Path, dst: &Path) -> std::io::Result<()> {
    for line in BufReader::new(fs::File::open(paths)?).lines() {
        let rel = line?;
        let rel = rel.trim();
        if rel.is_empty() {
            continue;
        }
        let to = dst.join(rel);
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent)?;
        }
        let from = store.join(rel);
        if fs::hard_link(&from, &to).is_err() {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

/// Does this encoded REAPI `ActionResult` record a FAILURE (top-level
/// field 4 `exit_code` != 0)? Conservative: malformed input reads as
/// "not a failure" so we never delete what we cannot parse.
fn is_failure_row(buf: &[u8]) -> bool {
    fn varint(buf: &[u8], mut i: usize) -> Option<(u64, usize)> {
        let mut v: u64 = 0;
        let mut shift = 0;
        loop {
            let b = *buf.get(i)?;
            v |= u64::from(b & 0x7f) << shift;
            i += 1;
            if b & 0x80 == 0 {
                return Some((v, i));
            }
            shift += 7;
            if shift > 63 {
                return None;
            }
        }
    }
    let mut i = 0;
    while i < buf.len() {
        let Some((tag, next)) = varint(buf, i) else {
            return false;
        };
        i = next;
        let (field, wire) = (tag >> 3, tag & 7);
        match wire {
            0 => {
                let Some((v, next)) = varint(buf, i) else {
                    return false;
                };
                i = next;
                if field == 4 && v != 0 {
                    return true;
                }
            }
            1 => i += 8,
            2 => {
                let Some((len, next)) = varint(buf, i) else {
                    return false;
                };
                i = next + usize::try_from(len).unwrap_or(usize::MAX);
            }
            5 => i += 4,
            _ => return false,
        }
    }
    false
}

/// Delete AC rows that cache FAILURES. The driver's --cache-failures
/// usefully dedupes repeated failures WITHIN a lap, but the AC write
/// path caches them and the read path serves them unconditionally
/// (rebuck2 rpc.rs) - so a banked environmental failure (the exec-bit
/// EACCES class) replays forever. Purging at seed time keeps in-lap
/// caching and stops the poison crossing laps.
fn ac_purge_failures(dir: &Path) -> std::io::Result<()> {
    let mut purged = 0u64;
    let mut kept = 0u64;
    // BOTH layouts: ac/ is flat (`ac/<digest>`), acn/ is `<xx>/<key>`.
    // A dir-only walk skipped every top-level FILE, so the digest-keyed
    // AC - where the poison actually lives - was never purged at all.
    fn sweep(f: &Path, purged: &mut u64, kept: &mut u64) -> std::io::Result<()> {
        if is_failure_row(&fs::read(f)?) {
            fs::remove_file(f)?;
            *purged += 1;
        } else {
            *kept += 1;
        }
        Ok(())
    }
    if dir.is_dir() {
        for d in fs::read_dir(dir)? {
            let d = d?;
            let ft = d.file_type()?;
            if ft.is_file() {
                sweep(&d.path(), &mut purged, &mut kept)?;
            } else if ft.is_dir() {
                for f in fs::read_dir(d.path())? {
                    let f = f?;
                    if !f.file_type()?.is_file() {
                        continue;
                    }
                    sweep(&f.path(), &mut purged, &mut kept)?;
                }
            }
        }
    }
    println!("purged {purged} failure rows, kept {kept}");
    Ok(())
}

/// Synthetic 64-hex blob name: the reversed hex of `i`, tiled to 64
/// chars. Reversal puts the varying nibble FIRST so names spread
/// evenly across all 16 prefixes.
fn synth_name(i: u64) -> String {
    let rev: String = format!("{i:08x}").chars().rev().collect();
    rev.repeat(8)
}

/// Test corpus: `n` small blobs laid out as a store (`cas/xx/<name>`).
fn gen_store(dir: &Path, n: u64) -> std::io::Result<()> {
    for i in 0..n {
        let name = synth_name(i);
        let d = dir.join("cas").join(&name[..2]);
        fs::create_dir_all(&d)?;
        fs::write(d.join(&name), i.to_string())?;
    }
    Ok(())
}

/// Test corpus: `n` AC rows - 3 in 4 digest-keyed (`ac/<name>`, flat), the
/// rest canonical (`acn/<xx>/<name>`), each holding a distinct payload.
fn gen_ac(dir: &Path, n: u64) -> std::io::Result<()> {
    let ac = dir.join("ac");
    fs::create_dir_all(&ac)?;
    for i in 0..n {
        let name = synth_name(i);
        let body = format!("row-{i}");
        if i % 4 == 3 {
            let d = dir.join("acn").join(&name[..2]);
            fs::create_dir_all(&d)?;
            fs::write(d.join(&name), &body)?;
        } else {
            fs::write(ac.join(&name), &body)?;
        }
    }
    Ok(())
}

/// Test corpus: `n` segment dirs (`cas-seg-<hash>/{meta.json,blobs.txt}`),
/// 20 synthetic blobs each. blobs.txt is left uncompressed for the
/// caller to zstd.
fn gen_segments(dir: &Path, n: u64) -> std::io::Result<()> {
    for i in 0..n {
        let name = synth_name(i);
        let d = dir.join(format!("cas-seg-{name}"));
        fs::create_dir_all(&d)?;
        let mut blobs: Vec<String> = (0..20).map(|j| synth_name(1 + i * 20 + j)).collect();
        blobs.sort();
        fs::write(d.join("blobs.txt"), blobs.join("\n") + "\n")?;
        let meta = format!(
            "{{\"name\":\"cas-seg-{name}\",\"bytes\":1000,\"blobs\":20,\"prefixes\":\"{}\"}}\n",
            &name[..1]
        );
        fs::write(d.join("meta.json"), meta)?;
    }
    Ok(())
}
