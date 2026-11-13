#!/usr/bin/env bash
# Curl-verifies the staging deploy through the ALB. Shared by run.sh and
# .github/workflows/deploy-staging.yml so both run the same checks.
#
# No DNS points at the Ingress hostnames, so this hits the ALB's own DNS
# name and sets the Host header the Ingress matches on. Retries cover the
# delay before new pod IPs pass the ALB's target health checks.
#
# Usage: ./verify.sh <alb-hostname>
set -euo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <alb-hostname>" >&2
  exit 1
fi
ALB_HOST="$1"

FAIL=0
check() {
  local host="$1" path="$2" want="$3" code=000
  for _ in $(seq 1 10); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "http://$ALB_HOST$path" || echo 000)
    if [ "$code" = "$want" ]; then
      echo "  $host$path -> HTTP $code"
      return 0
    fi
    sleep 5
  done
  echo "  $host$path -> HTTP $code (expected $want)" >&2
  FAIL=1
}
check api.csat-staging.internal /healthz 200
check api.csat-staging.internal /api/static-pages 200
check app.csat-staging.internal / 200

if [ "$FAIL" -ne 0 ]; then
  echo "==> verification FAILED" >&2
  exit 1
fi
echo "==> verification passed"
