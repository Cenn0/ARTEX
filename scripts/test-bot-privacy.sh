#!/usr/bin/env bash
# Offline regression for the public GitHub Actions bot log boundary.
# The API response may contain untrusted text; only the answer intended for a
# GitHub comment should leave ask_model on stdout. Never print raw errors.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

bot=.github/scripts/bot.sh
MAX_CHARS=8000
DEEPSEEK_API_KEY=synthetic-test-key
# These variables are consumed by the dynamically extracted function.
export MAX_CHARS DEEPSEEK_API_KEY
log() { printf '[bot] %s\n' "$*" >&2; }

# Load only the function under test, without executing the event dispatch.
eval "$(sed -n '/^ask_model()/,/^}$/p' "$bot")"
[ "$(type -t ask_model)" = function ] || { echo "ask_model missing" >&2; exit 1; }

# The mock prevents any external connection or real credential use.
curl() {
  case "$MOCK_CURL_RESPONSE" in
    error) printf '%s\n' '{"error":{"message":"SYNTHETIC_PRIVATE_MARKER"}}' ;;
    valid) printf '%s\n' '{"choices":[{"message":{"content":"synthetic safe reply"}}]}' ;;
    *) return 22 ;;
  esac
}

MOCK_CURL_RESPONSE=error
output=$(ask_model 'system' 'user payload' 2>&1)
case "$output" in
  *SYNTHETIC_PRIVATE_MARKER*) echo 'untrusted API error leaked to logs' >&2; exit 1 ;;
esac
case "$output" in
  *'response omitted'*) ;;
  *) echo 'missing sanitized API failure diagnostic' >&2; exit 1 ;;
esac

MOCK_CURL_RESPONSE=valid
output=$(ask_model 'system' 'user payload' 2>&1)
[ "$output" = 'synthetic safe reply' ] || { echo 'normal model answer changed' >&2; exit 1; }

# The event handler must not echo complete model responses to workflow logs.
if grep -Eq 'log "raw (json|response):' "$bot"; then
  echo 'untrusted model output logging reintroduced' >&2
  exit 1
fi

echo 'ok: bot responses are not copied into public CI diagnostics'
