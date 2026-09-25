#!/usr/bin/env bash
# lgx-icu: write the patches (against logos-package 4cdb302) and check that
# they apply cleanly to a pristine copy and reproduce the patched tree.
set -u
EXP=${REPO_ROOT}/.work/experiments/lgx-icu
mkdir -p "$EXP/logs" "$EXP/patches"
LOG="$EXP/logs/patches.log"
exec > >(tee "$LOG") 2>&1
ORIG=/nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source
NEW=$EXP/src/logos-package-4cdb302
P=$EXP/patches

mk() { # patchfile files...
  local out=$1; shift
  : > "$out"
  for f in "$@"; do
    diff -u --label "a/$f" --label "b/$f" "$ORIG/$f" "$NEW/$f" >> "$out"
  done
  echo "$(basename "$out"): $(grep -c '^+[^+]' "$out") added / $(grep -c '^-[^-]' "$out") removed lines"
}
mk "$P/0001-path_normalizer-use-icu-c-api.patch" src/core/path_normalizer.cpp
mk "$P/0002-cmake-android-platform-libicu.patch" CMakeLists.txt
mk "$P/0003-platform_variant-android-branch.patch" src/core/platform_variant.cpp tests/test_platform_variant.cpp
cat "$P/0001-path_normalizer-use-icu-c-api.patch" "$P/0002-cmake-android-platform-libicu.patch" \
    "$P/0003-platform_variant-android-branch.patch" > "$P/all-lgx-icu.patch"

echo "== every other file unchanged?"
diff -rq "$ORIG" "$NEW" | grep -v -e REVISION.lgx-icu

echo "== apply check on a pristine copy"
CHK=$EXP/patchcheck
rm -rf "$CHK"; cp -r "$ORIG" "$CHK"; chmod -R u+w "$CHK"
for p in 0001-path_normalizer-use-icu-c-api 0002-cmake-android-platform-libicu 0003-platform_variant-android-branch; do
  git -C "$CHK" apply "$P/$p.patch"; echo "$p git-apply exit=$?"
done
diff -rq "$CHK" "$NEW" | grep -v REVISION.lgx-icu
echo "pristine+patches == patched tree: $([ -z "$(diff -rq "$CHK" "$NEW" | grep -v REVISION.lgx-icu)" ] && echo yes || echo no)"
echo "== does 0001 also apply to the other locked revs (path_normalizer.cpp is byte-identical there)?"
for r in ias6bmsz9p8vilcg0f473m03w4y0568n rdzzxzbyjjf22gx3iypkc0655rl23cgf 416a5wqisqs500gc2yzjs7bamwbv0l9r 418s1x65hgjgcw7yspxdf0i08qy2smka; do
  git -C "/nix/store/$r-source" apply --check "$P/0001-path_normalizer-use-icu-c-api.patch"
  echo "  $r: git apply --check exit=$?"
done
ls -la "$P"
