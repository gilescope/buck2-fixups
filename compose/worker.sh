#!/usr/bin/env bash
# Worker container: joins the mesh and executes actions until the driver
# closes the control stream (end of build) — then exits 0.
set -euo pipefail
exec rebuck2 worker --session "$SESSION" --store /store --connect-wait-secs 600
