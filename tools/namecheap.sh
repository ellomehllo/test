#!/bin/bash
# Namecheap's official XML API via curl (no third-party tool). Credentials come from ~/.config/namecheap.env:
#   NAMECHEAP_API_USER=…   NAMECHEAP_API_KEY=…   (chmod 600; the key is never printed)
# The calling machine's public IP must be whitelisted in Namecheap → Profile → Tools → API Access.
#
#   tools/namecheap.sh check                 test the credentials (read-only)
#   tools/namecheap.sh nameservers           which nameservers vanarsathi.online uses (read-only)
#   tools/namecheap.sh records               DNS records at Namecheap (read-only; only meaningful on Namecheap DNS)
#   tools/namecheap.sh set-nameservers a b   point the domain at other nameservers (e.g. Cloudflare's)
#   tools/namecheap.sh reset-nameservers     go back to Namecheap's own DNS
set -euo pipefail
ENV="$HOME/.config/namecheap.env"
[ -f "$ENV" ] || { echo "Missing $ENV (NAMECHEAP_API_USER / NAMECHEAP_API_KEY)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV"
: "${NAMECHEAP_API_USER:?set in $ENV}" "${NAMECHEAP_API_KEY:?set in $ENV}"
SLD=vanarsathi; TLD=online
IP=$(curl -s https://api.ipify.org)

call() {   # call <Command> [extra form fields…]
  local cmd=$1; shift
  local args=(-s --fail-with-body https://api.namecheap.com/xml.response
    --data-urlencode "ApiUser=$NAMECHEAP_API_USER" --data-urlencode "ApiKey=$NAMECHEAP_API_KEY"
    --data-urlencode "UserName=$NAMECHEAP_API_USER" --data-urlencode "ClientIp=$IP" --data-urlencode "Command=$cmd")
  for f in "$@"; do args+=(--data-urlencode "$f"); done
  local out; out=$(curl "${args[@]}") || true
  if echo "$out" | grep -q 'Status="ERROR"'; then
    echo "Namecheap API error (calling from $IP):" >&2
    echo "$out" | sed -n 's:.*<Error Number="\([0-9]*\)">\(.*\)</Error>.*:  \1 \2:p' >&2
    exit 1
  fi
  echo "$out"
}

case "${1:-}" in
  check)
    call namecheap.domains.getList PageSize=100 | grep -o 'Name="[^"]*"' | sed 's/Name=/domain: /'
    echo "OK — API access works from $IP" ;;
  nameservers)
    call namecheap.domains.dns.getList "SLD=$SLD" "TLD=$TLD" \
      | sed -n 's:.*IsUsingOurDNS="\([a-z]*\)".*:Namecheap DNS in use\: \1:p; s:.*<Nameserver>\(.*\)</Nameserver>.*:nameserver\: \1:p' ;;
  records)
    call namecheap.domains.dns.getHosts "SLD=$SLD" "TLD=$TLD" \
      | grep -o '<host [^>]*>' | sed -E 's/.* Name="([^"]*)".* Type="([^"]*)".* Address="([^"]*)".* TTL="([^"]*)".*/\2  \1  →  \3  (TTL \4)/' ;;
  set-nameservers)
    shift; [ $# -ge 2 ] || { echo "usage: set-nameservers ns1 ns2 [ns3…]"; exit 1; }
    ns=$(IFS=,; echo "$*")
    call namecheap.domains.dns.setCustom "SLD=$SLD" "TLD=$TLD" "Nameservers=$ns" | grep -o 'Updated="[a-z]*"' ;;
  reset-nameservers)
    call namecheap.domains.dns.setDefault "SLD=$SLD" "TLD=$TLD" | grep -o 'Updated="[a-z]*"' ;;
  *) sed -n '2,12p' "$0" ;;
esac
