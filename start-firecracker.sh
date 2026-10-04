#!/usr/bin/env bash

set -euo pipefail

SOCKET="${1:?Użycie: $0 /ścieżka/do/firecracker.socket}"

curl --fail-with-body --silent --show-error --unix-socket "$SOCKET" \
  -X PUT http://localhost/actions \
  -H 'Content-Type: application/json' \
  -d '{"action_type":"InstanceStart"}'

echo
echo "microVM started"
