#!/usr/bin/env bash
# desktop-harness: record how the harness differs from the previous round's verify-call-routes harness
# (no upstream repo was modified; ev_probe is a new module under experiments/desktop-harness/src).
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
mkdir -p "$E/patches"
diff -u "$W/verify-call-routes/qt_loop.cpp" "$E/harness/qt_loop.cpp" > "$E/patches/qt_loop.cpp.vs-verify-call-routes.diff"
diff -u "$W/verify-call-routes/main.c" "$E/harness/main.c" > "$E/patches/main.c.vs-verify-call-routes.diff"
wc -l "$E/patches"/*.diff "$E/harness"/* "$E/src/ev_probe/src"/*
ls -la "$E" "$E/logs" "$E/out/introspect"
