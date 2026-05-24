#!/bin/sh
# Container HEALTHCHECK target.
# Exits 0 if /api/health responds with HTTP 200 and JSON contains "status":"ok".

URL="${HEALTHCHECK_URL:-http://127.0.0.1/api/health}"
BODY=$(curl -fsS --max-time 5 "$URL" 2>/dev/null) || exit 1
echo "$BODY" | grep -q '"status":"ok"' || exit 1
exit 0
