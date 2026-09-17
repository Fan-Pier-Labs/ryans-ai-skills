#!/usr/bin/env python3
"""Find duplicated code blocks across the repo without any external tool.

  scripts/dup-blocks.py [--repo .] [--out <dir>] [--window 8] [--min-chars 160] [--exclude dir ...]

Normalises each source file (strips whitespace, blank lines, comment-only lines, and
bracket-only lines), hashes every window of N normalised lines, and reports runs that
appear in two or more places (different files, or non-overlapping spots in one file).
Writes <out>/dup-blocks.json with the groups, largest first, and a duplication ratio for
production code and for tests separately. Pure read. jscpd / pylint's duplicate-code
checker are stricter and token-aware; run those too when available (see run-analyzers.sh).
"""
import argparse, hashlib, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _repo_files import list_files, is_source, is_test, read_text, language_of  # noqa: E402

TRIVIAL_RE = re.compile(r"^[\s{}()\[\];,]*$|^(end|else|pass|return|break|continue|done|fi|esac|\}\s*else\s*\{)[;:]?$|^(try|finally)\s*[:{]?$")
COMMENT_RE = re.compile(r"^\s*(//|#|\*|/\*|\*/|--|<!--|'''|\"\"\")")
IMPORT_RE = re.compile(r"^\s*(import\b|from\s+\S+\s+import\b|require\(|use\s+[\w:]+;|package\s|using\s+[\w.]+;)")


def normalise(text):
    out = []
    for i, raw in enumerate(text.split("\n"), 1):
        s = raw.strip()
        if not s or COMMENT_RE.match(s) or TRIVIAL_RE.match(s) or IMPORT_RE.match(s):
            continue
        out.append((i, re.sub(r"\s+", " ", s)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="."); ap.add_argument("--out", default=None)
    ap.add_argument("--window", type=int, default=8); ap.add_argument("--min-chars", type=int, default=160)
    ap.add_argument("--exclude", nargs="*", default=[])
    a = ap.parse_args()
    root = os.path.abspath(a.repo)
    files = [f for f in list_files(root, a.exclude) if is_source(f)]
    norm = {}; total_lines = {"prod": 0, "test": 0}
    for f in files:
        t = read_text(root, f)
        if t is None:
            continue
        n = normalise(t)
        if len(n) >= a.window:
            norm[f] = n
        total_lines["test" if is_test(f) else "prod"] += len(n)
    W = a.window
    windows = {}  # hash -> [(file, idx)]
    for f, n in norm.items():
        for i in range(len(n) - W + 1):
            chunk = "\n".join(s for _, s in n[i:i + W])
            if len(chunk) < a.min_chars:
                continue
            h = hashlib.blake2b(chunk.encode(), digest_size=12).digest()
            windows.setdefault(h, []).append((f, i))
    dup = {h: locs for h, locs in windows.items() if len(locs) > 1 and len({(f, i // W) for f, i in locs}) > 1}
    # merge consecutive windows into runs
    runs = []; consumed = set()
    for h, locs in sorted(dup.items(), key=lambda kv: kv[1][0]):
        if h in consumed:
            continue
        cur = tuple(sorted(locs)); length = W; consumed.add(h)
        while True:
            nxt = tuple(sorted((f, i + 1) for f, i in cur))
            # find a hash whose loc set equals nxt
            f0, i0 = nxt[0]
            n0 = norm[f0]
            if i0 + W > len(n0):
                break
            chunk = "\n".join(s for _, s in n0[i0:i0 + W])
            h2 = hashlib.blake2b(chunk.encode(), digest_size=12).digest()
            if h2 in dup and tuple(sorted(dup[h2])) == nxt and h2 not in consumed:
                consumed.add(h2); cur = nxt; length += 1
            else:
                break
        start = tuple(sorted(locs))
        entries = []
        for (f, i) in start:
            n = norm[f]
            entries.append({"file": f, "start_line": n[i][0], "end_line": n[min(i + length - 1, len(n) - 1)][0], "test": is_test(f)})
        # drop overlapping self-duplicates inside one file
        runs.append({"normalized_lines": length, "copies": len(entries), "locations": entries,
                     "snippet": norm[start[0][0]][start[0][1]][1][:100]})
    # collapse runs that are sub-runs of a longer one with the same file set
    runs.sort(key=lambda r: (-r["normalized_lines"] * r["copies"]))
    final = []
    for r in runs:
        fs = {(e["file"]) for e in r["locations"]}
        covered = False
        for q in final:
            if {(e["file"]) for e in q["locations"]} == fs:
                for e in r["locations"]:
                    for e2 in q["locations"]:
                        if e["file"] == e2["file"] and e2["start_line"] <= e["start_line"] and e["end_line"] <= e2["end_line"]:
                            covered = True
        if not covered:
            final.append(r)
    dup_lines = {"prod": 0, "test": 0}
    for r in final:
        for e in r["locations"][1:]:
            dup_lines["test" if e["test"] else "prod"] += r["normalized_lines"]
    ratio = {k: (round(100.0 * dup_lines[k] / total_lines[k], 1) if total_lines[k] else 0.0) for k in dup_lines}
    result = {"window": W, "files_scanned": len(norm), "normalized_lines": total_lines, "duplicated_lines": dup_lines,
              "duplication_pct": ratio, "groups": len(final), "largest_groups": final[:40]}
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "dup-blocks.json"), "w") as fh:
            json.dump(result, fh, indent=1)
    print(f"duplicates: {len(final)} group(s); production duplication ≈ {ratio['prod']}% of {total_lines['prod']} normalised lines; tests ≈ {ratio['test']}%")
    for r in final[:10]:
        locs = ", ".join(f"{e['file']}:{e['start_line']}-{e['end_line']}" for e in r["locations"][:4])
        print(f"  {r['normalized_lines']:3d} lines x{r['copies']}  {locs}")


if __name__ == "__main__":
    main()
