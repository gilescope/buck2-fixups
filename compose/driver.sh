#!/usr/bin/env bash
# Driver container: rebuck2 driver + buck2 build of $PATTERN via build-all.sh.
set -euo pipefail

echo "[compose-driver] session=$SESSION pattern=$PATTERN"
rebuck2 driver --grpc-port 9092 --min-workers 2 --no-local-exec \
    --session "$SESSION" --store /store > /tmp/driver.log 2>&1 &
DRIVER_PID=$!
tail -f /tmp/driver.log &

for _ in $(seq 1 120); do
    grep -q "worker 2 joined" /tmp/driver.log && break
    kill -0 "$DRIVER_PID" || { echo "driver died"; exit 1; }
    sleep 2
done
grep -q "worker 2 joined" /tmp/driver.log || { echo "workers never joined"; exit 1; }

cat > .buckconfig.local <<'EOF'
[build]
execution_platforms = fixups//platforms:re-exec

[buck2_re_client]
action_cache_address = grpc://127.0.0.1:9092
cas_address = grpc://127.0.0.1:9092
engine_address = grpc://127.0.0.1:9092
tls = false
EOF

rc=0
# word-split intentional: PATTERN may hold several target patterns
# shellcheck disable=SC2086
./build-all.sh $PATTERN || rc=$?

echo "[compose-driver] dispatch stats:"
grep -c -- "-> worker " /tmp/driver.log || true
grep -o -- "-> worker [0-9]*" /tmp/driver.log | sort | uniq -c || true
grep "requeueing" /tmp/driver.log || true
exit "$rc"
