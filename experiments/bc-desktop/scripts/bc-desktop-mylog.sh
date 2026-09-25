#!/usr/bin/env bash
# bc-desktop: rapidsnark's hard-coded trace log (MyLogFile.log) landed in the host's cwd (the project
# root) during run2. Count the proofs it records, then move it into the run2 logs (it is our artefact).
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
F=${REPO_ROOT}/MyLogFile.log
[ -f "$F" ] || { echo "no $F"; exit 0; }
echo "size: $(stat -c %s "$F") B, lines: $(wc -l < "$F")"
echo "groth16 proofs (Start Multiexp A): $(grep -c 'Start Multiexp A' "$F")"
echo "first: $(head -1 "$F")"
echo "last:  $(tail -1 "$F")"
echo "distinct messages:"; sed -E 's/^.{26}//' "$F" | sort | uniq -c | sort -rn | head -40
mv "$F" "$E/logs/run2/MyLogFile.log" && echo "moved to $E/logs/run2/MyLogFile.log"
