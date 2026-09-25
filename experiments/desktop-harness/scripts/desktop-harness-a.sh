#!/usr/bin/env bash
# desktop-harness (a): runtime introspection over lp_invoke(getPluginMethods/getPluginEvents/
# getPluginInterface) from the in-process host, vs lp_get_methods.
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
LIBLOGOS=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos
OUT=$E/out/introspect
mkdir -p "$E/logs" "$OUT" "$E/persist/a"
exec > >(tee "$E/logs/a-introspect.log") 2>&1
unset LD_LIBRARY_PATH
export LOGOS_HOST_PATH=$LIBLOGOS/bin/logos_host
export TMPDIR=$W/dh/a1
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
echo "TMPDIR=$TMPDIR (${#TMPDIR} chars)"
timeout 120 "$E/build/dh" "$E/modules" "$E/persist/a" introspect "$OUT" > "$E/logs/a-introspect-raw.log" 2>&1
echo "exit=$?"
grep -E '^\[ *[0-9]+ ms\]' "$E/logs/a-introspect-raw.log" | cut -c1-400
echo "== summary per file =="
python3 - "$OUT" <<'PY'
import json, os, sys
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    raw = open(os.path.join(d, f)).read().strip()
    try:
        v = json.loads(raw)
    except Exception as e:
        print(f"{f}: not JSON ({e}): {raw[:120]}")
        continue
    if isinstance(v, list):
        keys = sorted({k for x in v if isinstance(x, dict) for k in x})
        names = [x.get("name") for x in v if isinstance(x, dict)]
        types = sorted({str(x.get("type")) for x in v if isinstance(x, dict)})
        withsig = sum(1 for x in v if isinstance(x, dict) and x.get("signature"))
        withparams = sum(1 for x in v if isinstance(x, dict) and "parameters" in x)
        print(f"{f}: {len(v)} entries; with signature={withsig}; with parameters={withparams}; keys={keys}; types={types}")
        print(f"   names={names}")
        if f.startswith("lez_core.getPluginMethods"):
            for x in v:
                print(f"   {x.get('returnType')} {x.get('signature')}  params={[p.get('name') for p in x.get('parameters', [])]}")
        if v and isinstance(v[0], dict):
            print(f"   first={json.dumps(v[0])[:400]}")
    else:
        print(f"{f}: {type(v).__name__}: {raw[:200]}")
PY
echo "== leftover logos_host processes for this modules dir =="
pgrep -af "$E/modules" | cut -c1-160 || echo none
