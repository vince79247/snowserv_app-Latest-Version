#!/usr/bin/env bash
# Run the SnowServ dispatch routing regression test against the live database.
# Read-only — writes nothing. Prints PASS/FAIL per check; exits non-zero on any FAIL.
#
#   ./supabase/tests/run_dispatch_test.sh
#
# Auth: reuses the Supabase CLI access token from the macOS keychain (the same
# token `supabase` login stores). No secrets live in this file.
set -euo pipefail

REF="swttuujhcgpcsrxgupzv"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$HERE/dispatch_ranking_test.sql"

TOKEN="${SUPABASE_ACCESS_TOKEN:-$(security find-generic-password -s "Supabase CLI" -w 2>/dev/null || true)}"
if [ -z "$TOKEN" ]; then
  echo "No Supabase access token. Run 'supabase login', or set SUPABASE_ACCESS_TOKEN." >&2
  exit 2
fi

PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"query": open(sys.argv[1]).read()}))' "$SQL_FILE")"

RESP="$(curl -s -X POST "https://api.supabase.com/v1/projects/$REF/database/query" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "$PAYLOAD")"

echo "$RESP" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if not isinstance(d,list):
    print("ERROR running test:")
    print(json.dumps(d,indent=2))
    sys.exit(2)
fails=[r for r in d if r["result"]!="PASS"]
for r in d:
    print("  %-4s  %s" % (r["result"], r["check_name"]))
print("")
print("  %d checks - %d PASS, %d FAIL" % (len(d), len(d)-len(fails), len(fails)))
sys.exit(1 if fails else 0)
'
