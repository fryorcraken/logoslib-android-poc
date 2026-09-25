#!/usr/bin/env bash
# scripts/android/check-prefix.sh -- M2/M3 acceptance check: are the shared objects of an
# Android install prefix (and of the staged module directories) packageable in an APK and
# loadable by bionic?
#
# For every *.so / *.so.* file under the given prefix(es) it checks:
#   name     the file is named lib*.so (only those are packaged into / extracted from an APK)
#   SONAME   unversioned lib*.so equal to the file name (a NEEDED built from it resolves by
#            file name in nativeLibraryDir). Executables shipped as lib*.so (PT_INTERP set,
#            e.g. liblogos_host_qt.so) may have none.
#   NEEDED   each entry is an NDK system library for the target API (a stub exists in the
#            NDK sysroot), libc++_shared.so, a Qt 6 Android library (libQt6*_<abi>.so from
#            QT_ROOT), or another library found under the checked prefix(es). Versioned or
#            glibc names (libc.so.6, libstdc++.so.6, ld-linux*, ...) always fail.
#   SYMBOLS  every strong undefined dynamic symbol is defined by some library in the file's
#            transitive NEEDED closure. Bionic binds all symbols at load time (no lazy
#            binding), so a gap that glibc would only hit when the function is first
#            called makes the whole library fail to load on Android.
#   RUNPATH  empty or only $ORIGIN; no absolute path, no /nix/store
#   ALIGN    every PT_LOAD p_align >= 0x4000 (16 KB pages)
#   ABI      ELF machine matches the ABI; no GLIBC_* symbol versions; no "/nix/store" string
#            anywhere in the file
# Symlinks are listed but not checked (they are not packaged; the build prefix keeps a few
# for CMake, e.g. libssl.so -> libssl_3.so).
#
# Module directories (M3; --modules DIR, whose subdirectories are modules/<name>/): the
# files there ship in the APK's assets and are dlopen()ed by path, so they need not be
# named lib*.so. For each module:
#   manifest manifest.json parses, its name is the directory name, its type is "core", and
#            its `main` has an entry for this build's variant ($LGX_VARIANT, see env.sh)
#            that names a file in the directory, whose embedded Qt plugin metadata
#            (.note.qt.metadata) carries the same name
#   files    every *.so gets the checks above, except the lib*.so name rule; a SONAME, if
#            any, must equal the file name; a NEEDED may also be a sibling file of the module
#
# Prints one table row per file and exits non-zero if any check fails.
#
# Usage:
#   bash scripts/android/check-prefix.sh [x86_64|arm64-v8a] [PREFIX...] [--modules DIR]...
#     default: PREFIX build/android/<abi>/prefix, plus --modules build/android/<abi>/modules
#     when that directory exists. Several prefixes are checked together (a library in one
#     may satisfy a NEEDED of another).
#   Environment: ABI, ANDROID_API, ANDROID_NDK_HOME, QT_ROOT (see env.sh).
set -euo pipefail

PREFIXES=()
MODULE_ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    x86_64|arm64-v8a) ABI=$1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    --modules) shift; [ $# -gt 0 ] || { echo "--modules needs a directory" >&2; exit 2; }
               MODULE_ROOTS+=("$1") ;;
    *) PREFIXES+=("$1") ;;
  esac
  shift
done
export ABI="${ABI:-x86_64}"
export LC_ALL=C   # one collation for sort/comm
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup check-prefix tee
if [ ${#PREFIXES[@]} -eq 0 ]; then
  PREFIXES=("$PREFIX")
  [ ${#MODULE_ROOTS[@]} -gt 0 ] || [ ! -d "$ANDROID_BUILD/modules" ] || MODULE_ROOTS=("$ANDROID_BUILD/modules")
fi

# ---- what may be NEEDED ------------------------------------------------------------
# LIBPATH maps every acceptable NEEDED name to the file whose exports it provides.
declare -A NDK_LIBS=() QT_LIBS=() PREFIX_LIBS=() LIBPATH=() MODFILE_DIR=() MODSIB=()
[ -d "$NDK_SYSLIB_DIR" ] || { echo "no NDK stubs at $NDK_SYSLIB_DIR" >&2; exit 2; }
for f in "$NDK_SYSLIB_DIR"/*.so; do
  # Skip linker scripts (the sysroot's libc++.so is one; no such library exists on a device).
  "$READELF" -h "$f" >/dev/null 2>&1 || continue
  NDK_LIBS[$(basename "$f")]=1; LIBPATH[$(basename "$f")]=$f
done
LIBPATH[libc++_shared.so]=$LIBCXX_SHARED
if [ -d "$QT_ANDROID_PREFIX/lib" ]; then
  for f in "$QT_ANDROID_PREFIX"/lib/lib*.so; do QT_LIBS[$(basename "$f")]=1; LIBPATH[$(basename "$f")]=$f; done
else
  echo "note: no Qt at $QT_ANDROID_PREFIX; Qt libraries will not be accepted as NEEDED"
fi
FILES=()
for p in "${PREFIXES[@]}"; do
  [ -d "$p" ] || { echo "no such prefix: $p" >&2; exit 2; }
  while IFS= read -r f; do
    FILES+=("$f")
    # Only regular files are packaged, so only they can satisfy a NEEDED at run time.
    if [ ! -L "$f" ]; then PREFIX_LIBS[$(basename "$f")]=1; LIBPATH[$(basename "$f")]=$f; fi
  done < <(find "$p" \( -name '*.so' -o -name '*.so.*' \) \( -type f -o -type l \) | sort)
done
MODULE_DIRS=()
for r in "${MODULE_ROOTS[@]}"; do
  [ -d "$r" ] || { echo "no such modules directory: $r" >&2; exit 2; }
  for d in "$r"/*/; do
    d=${d%/}
    [ -d "$d" ] || continue
    MODULE_DIRS+=("$d")
    while IFS= read -r f; do
      FILES+=("$f")
      MODFILE_DIR[$f]=$d
      MODSIB[$d/$(basename "$f")]=1
      [ -L "$f" ] || { [ -n "${LIBPATH[$(basename "$f")]:-}" ] || LIBPATH[$(basename "$f")]=$f; }
    done < <(find "$d" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) \( -type f -o -type l \) | sort)
  done
done

# ---- symbol resolution: bionic binds every non-weak undefined symbol when a library is
# loaded (no lazy binding), so each one must be defined somewhere in its NEEDED closure.
SYMCACHE="$TMPDIR/check-prefix.$$"
mkdir -p "$SYMCACHE"
trap 'rm -rf "$SYMCACHE"' EXIT
defs_file() { # file -> file listing the names it defines (cached)
  local key; key=$(printf '%s' "$1" | sha256sum | cut -c1-16)
  local out="$SYMCACHE/$key.def"
  [ -f "$out" ] || "$NM" -D -P --defined-only "$1" 2>/dev/null | awk '{print $1}' | sed 's/@.*//' | sort -u > "$out"
  printf '%s\n' "$out"
}
needed_of() { "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
# resolve_needed FILE NAME: the file a NEEDED name of FILE loads (a module sibling first).
resolve_needed() {
  local d=${MODFILE_DIR[$1]:-}
  if [ -n "$d" ] && [ -n "${MODSIB[$d/$2]:-}" ]; then printf '%s\n' "$d/$2"; return; fi
  printf '%s\n' "${LIBPATH[$2]:-}"
}
# unresolved FILE: print the strong undefined symbols no library of the NEEDED closure defines.
unresolved() {
  local f=$1 n p q=() defs=()
  declare -A inq=()
  while IFS= read -r n; do q+=("$(resolve_needed "$f" "$n")"); done < <(needed_of "$f")
  while [ ${#q[@]} -gt 0 ]; do
    p=${q[0]}; q=("${q[@]:1}")
    [ -n "$p" ] || continue
    [ -n "${inq[$p]:-}" ] && continue
    inq[$p]=1
    defs+=("$(defs_file "$p")")
    while IFS= read -r n; do q+=("$(resolve_needed "$p" "$n")"); done < <(needed_of "$p")
  done
  "$NM" -D -P --undefined-only "$f" 2>/dev/null | awk '$2 == "U" {print $1}' | sed 's/@.*//' | sort -u \
    | comm -23 - <( [ ${#defs[@]} -gt 0 ] && sort -mu "${defs[@]}" )
}

echo "ABI=$ABI API=$ANDROID_API machine='$ELF_MACHINE' module variant=$LGX_VARIANT"
echo "prefixes: ${PREFIXES[*]}"
echo "modules:  ${MODULE_ROOTS[*]:-(none)} (${#MODULE_DIRS[@]} module directories)"
echo "allowed NEEDED: ${#NDK_LIBS[@]} NDK system libs ($NDK_SYSLIB_DIR), libc++_shared.so, ${#QT_LIBS[@]} Qt libs, ${#PREFIX_LIBS[@]} prefix files, module siblings"
echo

VIOLATIONS=0
fail() { ROW_FAIL+=("$1"); }
printf '%-44s %-7s %-9s %-7s %s\n' "FILE" "KIND" "SIZE" "ALIGN" "SONAME | NEEDED (c++=libc++_shared, ndk:, qt:, pfx:, mod:) | RESULT"
printf '%-44s %-7s %-9s %-7s %s\n' "----" "----" "----" "-----" "------"

# ---- module manifests ----------------------------------------------------------------
for d in "${MODULE_DIRS[@]}"; do
  ROW_FAIL=()
  mname=$(basename "$d")
  keys=()
  for a in $LGX_ARCH_NAMES; do keys+=("$LGX_OS-$a$LGX_DEV_SUFFIX"); done
  if [ ! -f "$d/manifest.json" ]; then
    fail "no manifest.json"
    main="-"
  elif ! main=$(python3 - "$d/manifest.json" "$mname" "${keys[@]}" <<'PY'
import json, os, sys
path, name, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
m = json.load(open(path))
errs = []
if m.get("name") != name: errs.append("name %r is not the directory name %r" % (m.get("name"), name))
if m.get("type") != "core": errs.append("type %r is not 'core'" % m.get("type"))
main = m.get("main")
hit = None
if isinstance(main, dict):
    for k in keys:
        if k in main: hit = main[k]; break
if hit is None: errs.append("main has no entry for %s" % " / ".join(keys))
elif not os.path.isfile(os.path.join(os.path.dirname(path), hit)): errs.append("main -> %r: no such file" % hit)
if errs:
    print("; ".join(errs)); sys.exit(1)
print(hit)
PY
  ); then
    fail "manifest.json: $main"
    main="-"
  elif ! "$OBJCOPY" -O binary --only-section=.note.qt.metadata "$d/$main" "$SYMCACHE/qtmeta.bin" 2>/dev/null \
       || ! python3 - "$SYMCACHE/qtmeta.bin" "$mname" <<'PY'
# The plugin's embedded Qt metadata (CBOR) must carry "name": "<module>": liblogos refuses a
# plugin whose metadata name differs from the package name.
import sys
blob, name = open(sys.argv[1], "rb").read(), sys.argv[2].encode()
def text(s):
    n = len(s)
    return (bytes([0x60 + n]) if n < 24 else bytes([0x78, n]) if n < 256 else bytes([0x79]) + n.to_bytes(2, "big")) + s
sys.exit(0 if text(b"name") + text(name) in blob else 1)
PY
  then
    fail "$main: its embedded Qt plugin metadata does not say name=\"$mname\""
  fi
  [ -f "$d/variant" ] && variant=$(head -1 "$d/variant") || variant="(no variant file)"
  if [ ${#ROW_FAIL[@]} -eq 0 ]; then result=OK; else result=FAIL; VIOLATIONS=$((VIOLATIONS + ${#ROW_FAIL[@]})); fi
  printf '%-44s %-7s %-9s %-7s %s\n' "$mname/manifest.json" "module" "-" "-" "main[$LGX_VARIANT] -> $main, variant $variant | $result"
  for r in "${ROW_FAIL[@]}"; do echo "      ! $r"; done
done

# ---- shared objects ------------------------------------------------------------------
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  rel=${f#"$(dirname "$(dirname "$f")")"/}
  moddir=${MODFILE_DIR[$f]:-}
  if [ -L "$f" ]; then
    tgt=$(readlink "$f")
    if [ -e "$f" ]; then
      printf '%-44s %-7s %-9s %-7s %s\n' "$rel" "symlink" "-" "-" "-> $tgt (not packaged; skipped)"
    else
      printf '%-44s %-7s %-9s %-7s %s\n' "$rel" "symlink" "-" "-" "-> $tgt DANGLING | FAIL"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
    continue
  fi
  ROW_FAIL=()
  hdr=$("$READELF" -h -l -d -W "$f" 2>&1) || { ROW_FAIL+=("not an ELF file"); hdr=""; }
  etype=$(printf '%s\n' "$hdr" | sed -n 's/^ *Type: *\([A-Z]*\).*/\1/p' | head -1)
  machine=$(printf '%s\n' "$hdr" | sed -n 's/^ *Machine: *//p' | head -1)
  soname=$(printf '%s\n' "$hdr" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
  mapfile -t needed < <(printf '%s\n' "$hdr" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
  runpath=$(printf '%s\n' "$hdr" | sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p' | tr '\n' ':')
  has_interp=0; printf '%s\n' "$hdr" | grep -q 'INTERP ' && has_interp=1
  kind=lib; [ "$has_interp" = 1 ] && kind=exe; [ -n "$moddir" ] && kind=plugin
  [ "$etype" = DYN ] || fail "ELF type '$etype' is not DYN"
  [ "$machine" = "$ELF_MACHINE" ] || fail "machine '$machine' is not '$ELF_MACHINE'"

  # name + SONAME
  if [ -n "$moddir" ]; then
    [[ "$name" =~ ^[^/]*\.so$ ]] || fail "module file name is not *.so"
    if [ -n "$soname" ] && [ "$soname" != "$name" ]; then fail "SONAME '$soname' differs from the file name"; fi
  else
    [[ "$name" =~ ^lib[^/]*\.so$ ]] || fail "file name is not lib*.so (not packageable)"
    if [ -n "$soname" ]; then
      [[ "$soname" =~ ^lib[^/]*\.so$ ]] || fail "SONAME '$soname' is not an unversioned lib*.so"
      [ "$soname" = "$name" ] || fail "SONAME '$soname' differs from the file name"
    elif [ "$has_interp" = 0 ]; then
      fail "no SONAME"
    fi
  fi

  # NEEDED
  nd=()
  for n in "${needed[@]}"; do
    if [[ "$n" =~ \.so\.[0-9] ]] || [[ "$n" =~ ^(ld-linux|libc\.so\.|libm\.so\.|libstdc\+\+|libgcc_s|libpthread|librt\.|libdl\.so\.) ]]; then
      fail "NEEDED $n is a versioned/glibc name"; nd+=("!$n")
    elif [ "$n" = libc++_shared.so ]; then nd+=("c++")
    elif [ -n "${NDK_LIBS[$n]:-}" ]; then nd+=("ndk:${n%.so}")
    elif [ -n "${QT_LIBS[$n]:-}" ]; then nd+=("qt:${n%.so}")
    elif [ -n "$moddir" ] && [ -n "${MODSIB[$moddir/$n]:-}" ]; then nd+=("mod:${n%.so}")
    elif [ -n "${PREFIX_LIBS[$n]:-}" ]; then nd+=("pfx:${n%.so}")
    else fail "NEEDED $n is not an NDK, libc++_shared, Qt or prefix library"; nd+=("!$n")
    fi
  done

  # every strong undefined symbol resolves within the NEEDED closure
  mapfile -t unres < <(unresolved "$f")
  if [ ${#unres[@]} -gt 0 ]; then
    fail "${#unres[@]} undefined symbol(s) defined by no library in the NEEDED closure: ${unres[*]:0:8}"
  fi

  # RUNPATH
  if [ -n "$runpath" ]; then
    IFS=: read -ra rps <<< "$runpath"
    for rp in "${rps[@]}"; do
      [ -z "$rp" ] || [ "$rp" = '$ORIGIN' ] || fail "RUNPATH/RPATH entry '$rp' (only \$ORIGIN allowed)"
    done
  fi

  # 16 KB alignment of every LOAD segment
  aligns=$(printf '%s\n' "$hdr" | awk '$1 == "LOAD" {print $NF}' | sort -u | tr '\n' ' ')
  [ -n "$aligns" ] || fail "no PT_LOAD segments"
  minalign=""
  for al in $aligns; do
    [ $((al)) -ge $((0x4000)) ] || fail "LOAD p_align $al < 0x4000"
    if [ -z "$minalign" ] || [ $((al)) -lt $((minalign)) ]; then minalign=$al; fi
  done

  # glibc symbol versions, /nix/store strings
  if "$READELF" -V -W "$f" 2>/dev/null | grep -q 'GLIBC_'; then fail "references GLIBC_* symbol versions"; fi
  if grep -q -a -F '/nix/store' "$f"; then fail "contains a /nix/store string"; fi

  size=$(stat -c %s "$f")
  if [ ${#ROW_FAIL[@]} -eq 0 ]; then result=OK; else result="FAIL"; VIOLATIONS=$((VIOLATIONS + ${#ROW_FAIL[@]})); fi
  printf '%-44s %-7s %-9s %-7s %s | %s | %s\n' "$rel" "$kind" "$size" "${minalign:-?}" \
    "${soname:-(none)}" "$(IFS=,; echo "${nd[*]}")" "$result"
  for r in "${ROW_FAIL[@]}"; do echo "      ! $r"; done
done

echo
if [ "$VIOLATIONS" -eq 0 ]; then
  echo "check-prefix: OK -- ${#FILES[@]} files and ${#MODULE_DIRS[@]} module manifests checked, no violations"
else
  echo "check-prefix: FAILED -- $VIOLATIONS violation(s)"
  exit 1
fi
