#!/bin/sh
# verify.sh - prove the public Funnel URL is live.
#
# Usage:
#   sh verify.sh https://<host>.<tailnet>.ts.net

set -u
URL="${1:-}"
if [ -z "$URL" ]; then
  echo "usage: sh verify.sh https://<host>.<tailnet>.ts.net" >&2
  exit 2
fi

echo "GET $URL/health"
curl -s -w '\nHTTP:%{http_code}\n' -m 30 "$URL/health"

echo
echo "GET $URL/  (403 is expected: gateway needs its auth token)"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' -m 30 "$URL/"
