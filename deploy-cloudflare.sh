#!/bin/bash
# Deploy the site to Cloudflare (Worker "aradhya": static assets + a small script for video Range requests).
# Copies only what the site serves into a clean folder, then uploads it with wrangler.
# Cloudflare rejects static files over 25 MiB, so the (currently unused) 99 MB Ram Naam recording is left out.
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/public"
cp cloudflare/worker.js cloudflare/wrangler.jsonc "$OUT/"
rsync -a --exclude '.git' --exclude 'supabase' --exclude 'cloudflare' --exclude 'CNAME' --exclude 'deploy-cloudflare.sh' \
  --exclude 'assets/ram-naam.mp3' ./ "$OUT/public/"
big=$(find "$OUT" -type f -size +25M)
if [ -n "$big" ]; then echo "Too large for Cloudflare (25 MiB):"; echo "$big"; exit 1; fi
cat > "$OUT/public/_headers" <<'EOF'
/assets/*
  Cache-Control: public, max-age=3600
EOF
cd "$OUT"   # run outside the repo so wrangler reads only this config
wrangler deploy "$@"
