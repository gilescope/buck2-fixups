//! CAS-bank helper: the fork-free hot paths of `ci/cas-bank.sh`.
//!
//! Shell loops fork per item and melt at fleet scale (run 29435672672:
//! 11 workers stalled 30min+); everything per-blob lives here instead.
//! Zero dependencies so `cargo build` works offline on every runner.
//!
//! Subcommands:
//!   index <store>               blob\tpath\tbytes for cas/xx/<hash>, blob-sorted
//!   tar <store> <batch> <out>   deterministic USTAR of batch's store-relative paths
//!   link <store> <paths> <dst>  hardlink (copy fallback) paths into dst
//!   gen-store <dir> <n>         synthetic corpus: n blobs across all prefixes
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
        ["tar", store, batch, out] => tar(Path::new(store), Path::new(batch), Path::new(out)),
        ["link", store, paths, dst] => link(Path::new(store), Path::new(paths), Path::new(dst)),
        ["gen-store", dir, n] => gen_store(Path::new(dir), n.parse().unwrap_or(0)),
        ["gen-segments", dir, n] => gen_segments(Path::new(dir), n.parse().unwrap_or(0)),
        ["ac-purge-failures", dir] => ac_purge_failures(Path::new(dir)),
        _ => {
            eprintln!(
                "usage: cas-bank-tool index <store> | tar <store> <batch> <out> \
                 | link <store> <paths> <dst> | gen-store <dir> <n> \
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
    if dir.is_dir() {
        for d in fs::read_dir(dir)? {
            let d = d?;
            if !d.file_type()?.is_dir() {
                continue;
            }
            for f in fs::read_dir(d.path())? {
                let f = f?;
                if !f.file_type()?.is_file() {
                    continue;
                }
                if is_failure_row(&fs::read(f.path())?) {
                    fs::remove_file(f.path())?;
                    purged += 1;
                } else {
                    kept += 1;
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
