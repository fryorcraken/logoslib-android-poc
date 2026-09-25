#!/usr/bin/env python3
"""List crates in logos-blockchain-c's android dependency closure that have a build script
(and their `links` key), from `cargo metadata --filter-platform x86_64-linux-android`.
Follows normal + build dependency edges (dev excluded). Also marks crates that are only
reached through build-dependencies (host-side)."""
import json, sys

meta = json.load(open(sys.argv[1]))
pk = {p["id"]: p for p in meta["packages"]}
nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
root = next(p["id"] for p in meta["packages"] if p["name"] == "logos-blockchain-c")

# target-side closure (normal edges only from target crates), host-side closure (build edges)
target, host = set(), set()
def walk(pid, side):
    s = target if side == "t" else host
    if pid in s:
        return
    s.add(pid)
    for d in nodes[pid]["deps"]:
        kinds = {k["kind"] for k in d["dep_kinds"]}
        if None in kinds:  # normal
            walk(d["pkg"], side)
        if "build" in kinds:
            walk(d["pkg"], "h")
walk(root, "t")

def has_build(p):
    return any("custom-build" in t["kind"] for t in p["targets"])

print(f"target-side crates: {len(target)}  host-side (build-dep) crates: {len(host)}")
print("\n## target-side crates with build.rs (compiled for android)")
for pid in sorted(target, key=lambda i: pk[i]["name"]):
    p = pk[pid]
    if has_build(p):
        src = (p.get("source") or "path").split("+")[0]
        print(f"{p['name']:45s} {p['version']:12s} links={p.get('links') or '-':22s} src={src}")
print("\n## crates with links= key (target side)")
for pid in sorted(target, key=lambda i: pk[i]["name"]):
    p = pk[pid]
    if p.get("links"):
        print(p["name"], p["version"], p["links"])
print("\n## features enabled on selected crates")
for pid in sorted(target, key=lambda i: pk[i]["name"]):
    p = pk[pid]
    if p["name"] in ("rocksdb", "librocksdb-sys", "openssl-sys", "openssl", "ring", "reqwest", "rusqlite",
                     "libsqlite3-sys", "zstd-sys", "lz4-sys", "bzip2-sys", "libz-sys", "rust-rapidsnark",
                     "aws-lc-sys", "aws-lc-rs", "rustls", "tikv-jemalloc-sys", "libp2p", "if-watch",
                     "netlink-sys", "hickory-resolver", "libc", "cc", "logos-blockchain-circuits-build",
                     "logos-blockchain-circuits-poc-sys", "blst", "secp256k1-sys", "libmimalloc-sys",
                     "snappy-sys", "prost-build", "native-tls", "openssl-src", "rustls-platform-verifier"):
        print(f"{p['name']} {p['version']}: {nodes[pid]['features']}")
