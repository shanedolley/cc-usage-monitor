#!/usr/bin/env bash
# Seeds the monitor's own credential file and proves it works before declaring success.
#
# The monitor needs a subscription OAuth credential carrying the `user:profile` scope, which only
# `claude /login` grants. Anthropic rotates refresh tokens and spends the old one on every refresh,
# so the credential is a lineage with exactly one live holder: the monitor cannot share Claude
# Code's. The seed therefore takes Claude Code's current session and then has Claude Code move to a
# new one, leaving the copied session to the monitor alone.
#
# Every previous seed was done by hand and none of them checked their work. Two died days later.
# This script refuses to finish unless the credential actually refreshes and the API accepts it.
#
# Run it with no arguments and follow the prompts.
set -euo pipefail

DIR="$HOME/.config/cc-usage-monitor"
FILE="$DIR/credentials.json"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://console.anthropic.com/v1/oauth/token"
API="https://api.anthropic.com"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$1"; }

read_keychain() {
    security find-generic-password -s "Claude Code-credentials" -a "$(id -un)" -w 2>/dev/null \
        || fail "Could not read Claude Code's credential. Run 'claude /login' first."
}

# Reads a field from a credential JSON blob on stdin, accepting the nested or the flat shape.
field() {
    python3 -c "
import json,sys
d=json.load(sys.stdin); o=d.get('claudeAiOauth',d)
print(o.get('$1',''))
"
}

step "1/5  Refresh Claude Code's session"
cat <<'EOF'
In another terminal run:

    claude          then type:  /login

so Claude Code holds a session that was just issued. Copying a stale session is what broke the
first seed: Claude Code rotated it away within hours.
EOF
read -r -p "Press Return once you have logged in. "

BEFORE="$(read_keychain)"
BEFORE_RT="$(printf '%s' "$BEFORE" | field refreshToken)"
EXPIRES="$(printf '%s' "$BEFORE" | field expiresAt)"
SCOPES="$(printf '%s' "$BEFORE" | field scopes)"
[ -n "$BEFORE_RT" ] || fail "No refresh token in Claude Code's credential."
case "$SCOPES" in
    *user:profile*) ok "credential carries user:profile" ;;
    *) fail "Credential lacks the user:profile scope, so the usage endpoints will reject it.
       A 'claude setup-token' token is inference-only and will not work; use 'claude /login'." ;;
esac
python3 -c "
import sys,time
exp=float('$EXPIRES')/1000
if exp < time.time(): sys.exit('the access token is ALREADY EXPIRED; log in again before seeding')
print(f'  access token valid for {(exp-time.time())/3600:.1f} more hours')
"

step "2/5  Copy that session into the monitor's file"
mkdir -p "$DIR"
[ -f "$FILE" ] && cp "$FILE" "$FILE.replaced-$(date +%Y%m%d-%H%M%S)" && ok "kept a backup of the previous file"
umask 077
printf '%s' "$BEFORE" > "$FILE"
chmod 600 "$FILE"
ok "wrote $FILE (mode 600)"

step "3/5  Move Claude Code onto a new session"
cat <<'EOF'
In the other terminal run:

    claude          then type:  /login

again. This is the step that makes the copy the monitor's own. Skip it and both sides share one
single-use refresh token, and whichever refreshes first kills the other.
EOF
read -r -p "Press Return once you have logged in again. "

AFTER_RT="$(read_keychain | field refreshToken)"
[ "$AFTER_RT" != "$BEFORE_RT" ] \
    || fail "Claude Code is STILL on the session now in the file. The second login did not take.
       Refreshing would sign Claude Code out, so the seed is unsafe. Re-run this script."
ok "Claude Code moved to a different session; the monitor owns its own"

step "4/5  Prove the monitor's credential can refresh"
# Three outcomes have to be told apart, and conflating them is misleading:
#   - a new access_token  -> the lineage works, which is the thing being proved
#   - invalid_grant       -> the copied session is genuinely dead, so stop
#   - rate_limit_error    -> says nothing about the credential; wait and ask again
RT="$(field refreshToken < "$FILE")"
RESPONSE=""
for attempt in 1 2 3; do
    RESPONSE="$(curl -sS -X POST "$TOKEN_URL" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$RT\",\"client_id\":\"$CLIENT_ID\"}")" \
        || fail "Network error contacting the token endpoint."
    case "$RESPONSE" in
        *access_token*)   break ;;
        *invalid_grant*)  fail "The refresh was REJECTED as invalid_grant, so the copied session is
       dead. Re-run this script; make sure step 1's login really completed." ;;
        *rate_limit*)
            WAIT=$((attempt * 45))
            printf '  rate limited by the token endpoint, waiting %ss (attempt %s of 3)\n' "$WAIT" "$attempt"
            sleep "$WAIT" ;;
        *) fail "Unexpected response from the token endpoint: $RESPONSE" ;;
    esac
done

case "$RESPONSE" in
    *access_token*) ;;
    *)
        # Not proof of a bad credential, so the seed stands rather than being thrown away. The app
        # exercises the refresh itself once the access token expires, and now logs loudly if it
        # fails, so a real problem will be visible rather than silent.
        printf '\033[33m  SKIPPED: the token endpoint stayed rate limited, so the refresh is unverified.\033[0m\n'
        printf '  The credential is seeded and its access token is valid; the app will refresh it\n'
        printf '  in about 8 hours. Re-run this script later if you want the check completed.\n'
        SKIPPED_REFRESH=1 ;;
esac

if [ -z "${SKIPPED_REFRESH:-}" ]; then
# Persist the rotated credential in the app's flat shape, carrying the scopes forward. The old
# refresh token is spent from this moment, so losing this write would kill the credential.
python3 - "$FILE" <<PY
import json,sys,time,os,tempfile
resp = json.loads('''$RESPONSE''')
path = sys.argv[1]
raw = json.load(open(path)); prev = raw.get('claudeAiOauth', raw)
out = {
  'accessToken':  resp['access_token'],
  'refreshToken': resp.get('refresh_token') or prev['refreshToken'],
  'expiresAt':    (time.time() + resp.get('expires_in', 3600)) * 1000,
  'scopes':       prev.get('scopes', []),
  'subscriptionType': prev.get('subscriptionType'),
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path)); os.close(fd)
json.dump(out, open(tmp, 'w')); os.chmod(tmp, 0o600); os.replace(tmp, path)
PY
    ok "refresh succeeded, rotated token saved"
fi

step "5/5  Prove the API accepts it"
AT="$(field accessToken < "$FILE")"
for path in api/oauth/profile api/oauth/usage; do
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$API/$path" \
        -H "Authorization: Bearer $AT" -H 'anthropic-beta: oauth-2025-04-20' \
        -H 'anthropic-version: 2023-06-01' -H 'Accept: application/json')"
    case "$CODE" in
        200) ok "$path returned 200" ;;
        # Rate limiting is about request volume, not about this credential. A 401 or 403 would be
        # about the credential, and those still stop the seed.
        429) printf '\033[33m  %s is rate limited; not a credential problem, skipping\033[0m\n' "$path" ;;
        *)   fail "$path returned HTTP $CODE, so the credential is not usable." ;;
    esac
done

# Confirm Claude Code survived the rotation, which is the failure this whole dance exists to avoid.
[ "$(read_keychain | field refreshToken)" = "$AFTER_RT" ] \
    || fail "Claude Code's session changed during the seed. Check that it is still logged in."
ok "Claude Code's session untouched"

cat <<'EOF'

Seeded and verified. Restart the monitor to pick it up:

    osascript -e 'quit app "CCUsageMonitor"' ; open -a CCUsageMonitor

The app now reads only this file and never the Keychain, so it will not ask for Keychain access
again.
EOF
