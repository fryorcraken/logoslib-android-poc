#!/usr/bin/env python3
"""bc-desktop: are the Bedrock circuit artefacts (zkey / witness .dat / verification key) embedded in
liblogos_blockchain.so? For each artefact take 5 64-byte slices at spread offsets and look for them
in the .so bytes (mmap). Run via bc-desktop-payload.sh."""
import mmap, os, sys

so_path, circ_root = sys.argv[1], sys.argv[2]
with open(so_path, "rb") as f:
    so = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    print(f"so: {so_path} ({len(so)} bytes)  circuits: {circ_root}")
    total_embedded = 0
    for c in ("pol", "poq", "poc", "signature"):
        for name in ("proving_key.zkey", "witness_generator.dat", "verification_key.json"):
            p = os.path.join(circ_root, c, name)
            if not os.path.exists(p):
                continue
            data = open(p, "rb").read()
            n = len(data)
            hits, first = 0, None
            for k in range(5):
                off = int(n * (0.1 + 0.2 * k))
                off = min(off, max(0, n - 64))
                chunk = data[off:off + 64]
                pos = so.find(chunk)
                if pos >= 0:
                    hits += 1
                    if first is None:
                        first = pos - off
            if hits >= 4:
                total_embedded += n
            print(f"{c:10s} {name:24s} size={n:10d} probes_found={hits}/5 approx_start_in_so={first}")
    print(f"total bytes of artefacts found embedded (>=4/5 probes): {total_embedded} ({total_embedded/1048576:.1f} MiB)")
