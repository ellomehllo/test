#!/bin/bash
# Put an Android build on Cloudflare R2, where vanarsathi.online/download/sadhana.apk serves it.
#   tools/upload-apk.sh                → the latest GitHub release of vanarsathi-android
#   tools/upload-apk.sh path/to/app.apk → that file
# Needs `npx wrangler login` once.
set -euo pipefail
cd "$(dirname "$0")/.."
APK=${1:-}
if [ -z "$APK" ]; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  gh release download -R ellomehllo/vanarsathi-android -p vanarsathi.apk -D "$TMP"
  APK=$TMP/vanarsathi.apk
fi
echo "uploading $(du -h "$APK" | cut -f1) …"
npx wrangler r2 object put sadhana-downloads/sadhana.apk --file "$APK" --remote \
  --content-type application/vnd.android.package-archive
echo "check: $(curl -sI https://vanarsathi.online/download/sadhana.apk | head -1)"
