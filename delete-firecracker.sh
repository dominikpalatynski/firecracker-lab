#!/usr/bin/env bash

set -euo pipefail

FC_SOCKET="${FC_SOCKET:-/tmp/firecracker.socket}"
test -S "$FC_SOCKET"

curl --fail-with-body -i --unix-socket "$FC_SOCKET" \
  -X PUT http://localhost/actions \
  -H 'Content-Type: application/json' \
  -d '{"action_type":"SendCtrlAltDel"}'

rm -f -- "$FC_SOCKET"
