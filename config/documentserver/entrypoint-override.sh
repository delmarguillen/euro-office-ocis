#!/bin/bash

# Workaround for WOPI proof key bug in Euro-Office DocumentServer.
# The entrypoint's awk command double-escapes newlines in the PEM key
# before jq processes it, resulting in an invalid key in local.json.
# See: https://github.com/Euro-Office/DocumentServer/issues/127
#
# This script lets the entrypoint run, then fixes the key in local.json
# by replacing literal \n with real newlines.

# Block healthcheck until key is fixed
rm -f /tmp/wopi-ready

# Run original entrypoint in background
/entrypoint.sh &
DS_PID=$!

# Wait for local.json to be written with WOPI keys
for i in $(seq 1 120); do
  if [ -f /etc/euro-office/documentserver/local.json ] && grep -q "privateKey" /etc/euro-office/documentserver/local.json 2>/dev/null; then
    break
  fi
  sleep 1
done

# Wait for docservice to start
for i in $(seq 1 60); do
  if curl -sf http://localhost/hosting/discovery > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Fix the double-escaped newlines in the WOPI private key
python3 << 'PYEOF'
import json, sys

with open("/etc/euro-office/documentserver/local.json", "r") as f:
    cfg = json.load(f)

key = cfg["wopi"]["privateKey"]
fixed = key.replace("\\n", "\n")

if fixed != key:
    cfg["wopi"]["privateKey"] = fixed
    cfg["wopi"]["privateKeyOld"] = fixed
    with open("/etc/euro-office/documentserver/local.json", "w") as f:
        json.dump(cfg, f, indent=2)
    print("WOPI private key fixed: restored real newlines", file=sys.stderr)
else:
    print("WOPI private key already has real newlines, no fix needed", file=sys.stderr)
PYEOF

# Restart docservice and converter to load the fixed key
supervisorctl restart docservice 2>/dev/null
supervisorctl restart converter 2>/dev/null

# Wait for docservice to come back up
for i in $(seq 1 30); do
  if curl -sf http://localhost/hosting/discovery > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Allow healthcheck to pass
touch /tmp/wopi-ready
echo "WOPI key fix complete, healthcheck unblocked" >&2

wait $DS_PID
