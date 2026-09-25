#!/usr/bin/env bash
# bc-desktop: write the (config-level) changes used in the runs as unified diffs, each with a one-line rationale.
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
PD="$E/patches"
mkdir -p "$PD"
NS=$(cat "$E/logs/nodesrc.path")
{
echo "# rationale: mempool.tx_ttl is the only key-level difference between devnet 0.3.0-rc.4's deployment and node 35a4a666's schema (deploydiff.txt); added preemptively (parsing without it was not tried). With it, the master-built module joined devnet (run3)."
diff -u --label a/settings-0.3.0-rc.4.yaml --label b/deployment-devnet-0.3.0-rc.4.yaml "$E/deployments/settings-0.3.0-rc.4.yaml" "$E/devnet-data/deployment-devnet-0.3.0-rc.4.yaml"
} > "$PD/01-devnet-deployment-tx_ttl.diff"
{
echo "# rationale: run the node repo's standalone single-node chain inside logoscore without port clashes and with state/logs under the experiment dir (ports 3000->3210, API 8080->18481, absolute state/log dirs)."
diff -u --label a/nodes/node/standalone-node-config.yaml --label b/standalone/node.yaml "$NS/nodes/node/standalone-node-config.yaml" "$E/standalone/node.yaml"
} > "$PD/02-standalone-node-config-paths-ports.diff"
{
echo "# rationale: the module's runtime doctest step 'Shorten the bootstrap period' (prolonged_bootstrap_period 3600s -> 5s) as applied to the generated config in run1."
echo "--- a/user_config.yaml (generated)"
echo "+++ b/user_config.yaml"
echo "-      prolonged_bootstrap_period: '3600.000000000'"
echo "+      prolonged_bootstrap_period: '5.000000000'"
} > "$PD/03-generated-config-short-bootstrap.diff"
ls -la "$PD"
head -3 "$PD"/*.diff
