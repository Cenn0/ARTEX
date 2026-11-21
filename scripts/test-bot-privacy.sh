#!/usr/bin/env bash
# Offline regression for the public GitHub Actions bot log boundary.
# Untrusted API error bodies must never appear in stdout or stderr. A failed
# request must yield an empty answer so handlers cannot post error diagnostics.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

bot=.github/scripts/bot.sh
MAX_CHARS=8000
DEEPSEEK_API_KEY=synthetic-test-key
# Variables are consumed by dynamically extracted functions.
export MAX_CHARS DEEPSEEK_API_KEY

# Evaluate only the real logger and API function, not event dispatch.
eval "$(sed -n -e '/^log()/p' -e '/^ask_model()/,/^}$/p' "$bot")"
[ "$(type -t ask_model)" = function ] || { echo 'ask_model missing' >&2; exit 1; }
[ "$(type -t log)" = function ] || { echo 'log missing' >&2; exit 1; }

# Function mock prevents real HTTP requests and credentials.
curl() {
  case "$MOCK_CURL_RESPONSE" in
    error) printf '%s\n' '{"error":{"message":"SYNTHETIC_PRIVATE_MARKER"}}' ;;
    valid) printf '%s\n' '{"choices":[{"message":{"content":"synthetic safe reply"}}]}' ;;
    *) return 22 ;;
  esac
}

stderr_file=$(mktemp)
trap 'rm -f "$stderr_file"' EXIT

MOCK_CURL_RESPONSE=error
output=$(ask_model 'system' 'user payload' 2>"$stderr_file")
[ -z "$output" ] || { echo 'API failure became a comment response' >&2; exit 1; }
if grep -Fq 'SYNTHETIC_PRIVATE_MARKER' "$stderr_file"; then
  echo 'untrusted API error leaked to public diagnostics' >&2
  exit 1
fi
grep -Fq 'response omitted' "$stderr_file" || {
  echo 'sanitized API error diagnostic missing' >&2
  exit 1
}

MOCK_CURL_RESPONSE=valid
output=$(ask_model 'system' 'user payload' 2>"$stderr_file")
[ "$output" = 'synthetic safe reply' ] || { echo 'normal model answer changed' >&2; exit 1; }

# The event handler must never echo the complete model response into logs.
if grep -Eq 'log "raw (json|response):' "$bot"; then
  echo 'untrusted model output logging reintroduced' >&2
  exit 1
fi

echo 'ok: bot returns no response after API failure and redacts CI diagnostics'
