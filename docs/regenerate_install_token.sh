#!/bin/bash
# regenerate_install_token.sh
# Regenerates a GitHub App installation access token for git operations.
# Expires in ~1 hour (55 minutes by default).
#
# Prerequisites:
#   - APP_ID in ~/.openclaw/tmp/bot-app-id.txt
#   - Private key in ~/.openclaw/tmp/bot-key.pem
#   - Python3 available
#
# Output: saves installation token to ~/.openclaw/tmp/install-token.txt
#
# Usage: save this to ~/.openclaw/tmp/regenerate_install_token.sh and run it
# when the token expires (usually after ~1 hour).

set -euo pipefail

PEM_PATH="/home/node/.openclaw/tmp/bot-key.pem"
APP_ID="5743676"
TOKEN_FILE="/home/node/.openclaw/tmp/install-token.txt"

if [ ! -f "$PEM_PATH" ]; then
    echo "ERROR: Private key not found at $PEM_PATH"
    exit 1
fi

NOW=$(date +%s)

# Generate JWT
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '+/' '-_')
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$NOW" "$((NOW + 600))" "$APP_ID" | base64 | tr -d '=' | tr '+/' '-_')
SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign "$PEM_PATH" 2>/dev/null | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

# Get installation ID
INST_ID=$(curl -s -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
  https://api.github.com/app/installations | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for inst in data:
    if inst['account']['login'] == 'dstewen':
        print(inst['id'])
        sys.exit(0)
print('ERROR: dstewen installation not found')
sys.exit(1)
")

# Get installation access token
curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/$INST_ID/access_tokens" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['token'])
" > "$TOKEN_FILE"

echo "Installation token regenerated: $TOKEN_FILE"
