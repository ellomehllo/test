#!/bin/bash
# Send an iPhone push notification to everyone with the app (or one account).
#   PUSH_SECRET=… tools/send-push.sh "Title" "Message"            → everyone
#   PUSH_SECRET=… tools/send-push.sh "Title" "Message" <user-id>  → one account
set -euo pipefail
: "${PUSH_SECRET:?set PUSH_SECRET to the secret you gave the send-push function}"
TITLE=${1:?title}; BODY=${2:?message}; USER=${3:-}
DATA=$(python3 -c 'import json,sys; d={"title":sys.argv[1],"body":sys.argv[2]}; u=sys.argv[3]; d.update({"userId":u} if u else {}); print(json.dumps(d))' "$TITLE" "$BODY" "$USER")
curl -s -X POST https://brtlirkvtkocdxginvlj.supabase.co/functions/v1/send-push \
  -H "x-push-secret: $PUSH_SECRET" -H "content-type: application/json" -d "$DATA"
echo
