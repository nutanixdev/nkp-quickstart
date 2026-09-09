#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load only the production scroll/input functions; this does not execute the
# deployment script or contact any external system.
eval "$(sed -n '/^deployment_scroll_up()/,/^render_deployment_output()/ { /^render_deployment_output()/!p; }' "$SCRIPT_DIR/nkpDeploy.sh")"

ROWS=10
DEPLOY_LOG_LINES=()
for ((INDEX=1; INDEX<=100; INDEX++)); do
    DEPLOY_LOG_LINES+=("line $INDEX")
done

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_state() {
    local LABEL="$1"
    local EXPECTED_FOLLOW="$2"
    local EXPECTED_OFFSET="$3"
    [[ "${DEPLOY_SCROLL_FOLLOW:-}" == "$EXPECTED_FOLLOW" ]] || \
        fail "$LABEL follow=${DEPLOY_SCROLL_FOLLOW:-unset}, expected $EXPECTED_FOLLOW"
    [[ "${DEPLOY_SCROLL_OFFSET:-}" == "$EXPECTED_OFFSET" ]] || \
        fail "$LABEL offset=${DEPLOY_SCROLL_OFFSET:-unset}, expected $EXPECTED_OFFSET"
}

feed_one_key() {
    local INPUT="$1"
    exec 3< <(printf '%b' "$INPUT")
    local KEY=""
    IFS= read -r -s -n 1 -u 3 KEY || true
    deployment_handle_key "$KEY" "$ROWS"
    exec 3<&-
}

feed_delayed_sgr() {
    exec 3< <(printf '\033'; sleep 0.1; printf '[<64;35;11M')
    local KEY=""
    IFS= read -r -s -n 1 -u 3 KEY || true
    deployment_handle_key "$KEY" "$ROWS"
    exec 3<&-
}

DEPLOY_SCROLL_FOLLOW=1
DEPLOY_SCROLL_OFFSET=0
feed_one_key '\033[<64;35;11M'
assert_state 'SGR wheel up' 0 87
feed_one_key '\033[<65;35;11M'
assert_state 'SGR wheel down' 1 0

DEPLOY_SCROLL_FOLLOW=1
DEPLOY_SCROLL_OFFSET=0
feed_one_key '\033[M\140\043\043'
assert_state 'X10 wheel up' 0 87
feed_one_key '\033[M\141\043\043'
assert_state 'X10 wheel down' 1 0

DEPLOY_SCROLL_FOLLOW=1
DEPLOY_SCROLL_OFFSET=0
feed_one_key '\033[A'
assert_state 'Arrow up' 0 89
feed_one_key '\033[B'
assert_state 'Arrow down' 1 0

DEPLOY_SCROLL_FOLLOW=1
DEPLOY_SCROLL_OFFSET=0
feed_delayed_sgr
assert_state 'Delayed SGR wheel up' 0 87

DEPLOY_CANCELLED=0
DEPLOY_REVIEW_DONE=0
feed_one_key '\003'
[[ "$DEPLOY_CANCELLED" == 1 ]] || fail 'Ctrl-C was not captured'
[[ "$DEPLOY_REVIEW_DONE" == 1 ]] || fail 'Ctrl-C did not stop review input'

printf 'PASS: SGR, X10, arrow, and Ctrl-C input handling\n'
