#!/usr/bin/env bash
# qt-jvmless: symbolize libQt6Core_x86_64.so frames of the X1 crashes (T0a none, T0b appversion).
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
exec > >(tee "$EXP/logs/symbolize.log") 2>&1
QT=${REPO_ROOT}/.work/probe/qt/6.11.1/android_x86_64
BIN=${HOME}/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin
LIB="$QT/lib/libQt6Core_x86_64.so"
sym() {
  python3 - "$BIN/llvm-nm" "$BIN/llvm-symbolizer" "$LIB" "$@" <<'EOF'
import subprocess, sys, bisect
nm, symb, lib, pcs = sys.argv[1], sys.argv[2], sys.argv[3], [int(a, 16) for a in sys.argv[4:]]
out = subprocess.run([nm, "-D", "--defined-only", "-C", "-n", lib], capture_output=True, text=True).stdout
syms = []
for line in out.splitlines():
    parts = line.split(" ", 2)
    if len(parts) == 3 and parts[1] in "TtWw":
        try: syms.append((int(parts[0], 16), parts[2]))
        except ValueError: pass
syms.sort()
addrs = [s[0] for s in syms]
for i, pc in enumerate(pcs):
    j = bisect.bisect_right(addrs, pc) - 1
    a, n = syms[j]
    s = subprocess.run([symb, "--obj=" + lib, "--demangle", hex(pc)], capture_output=True, text=True).stdout.split("\n")[0]
    print(f"#{i:02d} {pc:#x}: symbolizer={s} | nearest-dynsym={n} +{pc - a:#x}")
EOF
}
echo "== T0a jvm-mode=none =="
sym 530c7e 5364ff 5364e6 4fb042 393294 394496 3943ab
echo "== T0b jvm-mode=appversion =="
sym 530c7e 5364ff 5364e6 4fb042 52ada9 52a4dc 52b4b6 379f1c 36ffc4 36f7a4 370bf2 3944c8 3943ab
