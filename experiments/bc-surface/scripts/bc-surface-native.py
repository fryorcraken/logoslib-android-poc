#!/usr/bin/env python3
"""bc-surface: native-crate inventory for logos-blockchain-c.

Usage: bc-surface-native.py <Cargo.lock> <cargo-tree.txt> <cargo-metadata.json|->

1. BFS over Cargo.lock from logos-blockchain-c (over-approximation: ignores
   target cfgs and features, includes workspace dev-deps).
2. Exact package set from a `cargo tree -e normal,build --target <android>` dump.
3. For the exact set, every crate that is -sys, has a `links` key or a build
   script (from cargo metadata, if given).
"""
import json
import re
import sys
import tomllib

lock_path, tree_path, meta_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(lock_path, "rb") as f:
    lock = tomllib.load(f)

pkgs = {}
for p in lock["package"]:
    pkgs.setdefault(p["name"], []).append(p)


def resolve(dep):
    # "name", "name version", "name version (source)"
    parts = dep.split(" ")
    name = parts[0]
    cands = pkgs.get(name, [])
    if len(parts) > 1:
        cands = [c for c in cands if c["version"] == parts[1]] or cands
    return cands


root = pkgs["logos-blockchain-c"][0]
seen = set()
stack = [root]
while stack:
    p = stack.pop()
    key = (p["name"], p["version"])
    if key in seen:
        continue
    seen.add(key)
    for d in p.get("dependencies", []):
        for c in resolve(d):
            stack.append(c)

lock_sys = sorted(k for k in seen if k[0].endswith("-sys") or k[0].endswith("_sys"))
print("# Cargo.lock BFS from logos-blockchain-c: %d packages (over-approximation)" % len(seen))
print("# -sys crates reachable in Cargo.lock:")
for n, v in lock_sys:
    print("LOCK-SYS\t%s\t%s" % (n, v))

tree = set()
pat = re.compile(r"([A-Za-z0-9_\-]+) v(\d[^\s]*)")
for line in open(tree_path):
    m = pat.search(line)
    if m:
        tree.add((m.group(1), m.group(2)))
print("\n# cargo tree (normal+build, android target): %d unique packages" % len(tree))
tree_sys = sorted(k for k in tree if k[0].endswith("-sys") or k[0].endswith("_sys"))
for n, v in tree_sys:
    print("TREE-SYS\t%s\t%s" % (n, v))
dropped = [k for k in lock_sys if k not in tree]
print("\n# -sys crates in Cargo.lock BFS but NOT in the android normal+build tree:")
for n, v in dropped:
    print("LOCK-ONLY\t%s\t%s" % (n, v))

if meta_path != "-":
    meta = json.load(open(meta_path))
    rows = []
    for p in meta["packages"]:
        key = (p["name"], p["version"])
        if key not in tree:
            continue
        has_build = any("custom-build" in t["kind"] for t in p["targets"])
        links = p.get("links")
        is_sys = p["name"].endswith("-sys") or p["name"].endswith("_sys")
        if has_build or links or is_sys:
            src = p.get("source") or "path"
            rows.append((p["name"], p["version"], "build.rs" if has_build else "-",
                         "links=" + links if links else "-", "SYS" if is_sys else "-", src))
    rows.sort()
    print("\n# %d tree crates with build script/links/-sys" % len(rows))
    for r in rows:
        print("NATIVE\t" + "\t".join(r))
