#!/usr/bin/env bash
# desktop-harness: assemble the modules dir (capability_module + lez_core 0.4.2 + lez_probe from the
# desktop-probe install, ev_probe from desktop-harness-evprobe.sh) and build the in-process lp_* harness
# against the SAME liblogos (db45024, /nix/store/7jcna50...) + Qt 6.9.2 that logoscore 6a0a2f4 uses.
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
P=$W/probe
LIBLOGOS=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos
QT=/nix/store/dkfr32yi7p8cdxsnll05q1kax19fl7ay-qtbase-6.9.2
mkdir -p "$E/logs" "$E/build" "$E/modules" "$E/bin" "$W/dh"
exec > >(tee "$E/logs/build.log") 2>&1

echo "== modules dir =="
for m in capability_module lez_core lez_probe; do
  rm -rf "$E/modules/$m"
  cp -rL "$P/modules/$m" "$E/modules/$m"
  chmod -R u+w "$E/modules/$m"
done
ls -la "$E/modules"
for m in capability_module lez_core lez_probe ev_probe; do
  echo "--- $m: $(grep -o '"version": "[^"]*"' "$E/modules/$m/manifest.json" | head -1)"
done

echo "== which Qt / liblogos do the runtime pieces use? =="
readelf -d "$LIBLOGOS/lib/liblogos_core.so" | grep -E 'RUNPATH|NEEDED' | tr -s ' ' | cut -c1-400
file -L "$LIBLOGOS/bin/logos_host" "$LIBLOGOS/bin/logos_host_qt"
readelf -d "$E/modules/lez_core/lez_core_plugin.so" | grep RUNPATH | cut -c1-400
readelf -d "$E/modules/ev_probe/ev_probe_plugin.so" | grep RUNPATH | cut -c1-400

echo "== slow-host wrapper (delays the child's exec for lez_probe / ev_probe only) =="
cat > "$E/bin/slow_host.sh" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" --name lez_probe "*|*" --name ev_probe "*) sleep "\${DH_SLOW_HOST_S:-3}" ;;
esac
exec $LIBLOGOS/bin/logos_host "\$@"
EOF
chmod +x "$E/bin/slow_host.sh"
cat "$E/bin/slow_host.sh"

echo "== build =="
cat > "$E/build/build.sh" <<EOF
set -e
cd "$E/build"
g++ --version | head -1
g++ -std=c++17 -O1 -g -fPIC -Wall -c ../harness/qt_loop.cpp -o qt_loop.o -I$QT/include -I$QT/include/QtCore -I$LIBLOGOS/include
gcc -std=gnu11 -O1 -g -Wall -c ../harness/main.c -o main.o -I$LIBLOGOS/include
g++ -o dh main.o qt_loop.o -L$LIBLOGOS/lib -llogos_core -llogos_protocol -L$QT/lib -lQt6Core -Wl,-rpath,$LIBLOGOS/lib -Wl,-rpath,$QT/lib -lpthread
echo BUILD_OK
EOF
nix develop --no-write-lock-file "path:${HOME}/src/logos-co/logos-liblogos" -c bash "$E/build/build.sh" 2>&1 | tail -20
echo "== ldd dh (Qt/logos lines) =="
ldd "$E/build/dh" | grep -E 'Qt6|logos|not found|libstdc'
