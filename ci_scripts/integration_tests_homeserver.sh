#!/bin/bash

# A throwaway Synapse for the integration tests, bound to localhost, with the user and the room the tests use.
# Usage: integration_tests_homeserver.sh start|stop

set -euo pipefail

SYNAPSE_VERSION="1.143.0"
HOMESERVER_URL="http://127.0.0.1:8008"
SERVER_NAME="localhost"
USERNAME="integration-tests"
INVITEE="invitee"
ROOM_NAME="Element X iOS Integration Tests"
DIRECTORY="${RUNNER_TEMP:-/tmp}/integration-tests-homeserver"

start() {
    mkdir -p "$DIRECTORY"
    python3 -m venv "$DIRECTORY/venv"
    "$DIRECTORY/venv/bin/pip" install --quiet "matrix-synapse==$SYNAPSE_VERSION"

    "$DIRECTORY/venv/bin/python" -m synapse.app.homeserver \
        --server-name "$SERVER_NAME" \
        --config-path "$DIRECTORY/homeserver.yaml" \
        --data-directory "$DIRECTORY" \
        --generate-config \
        --report-stats=no

    cat > "$DIRECTORY/overrides.yaml" <<EOF
public_baseurl: $HOMESERVER_URL/
listeners:
  - port: 8008
    bind_addresses: ['127.0.0.1']
    type: http
    x_forwarded: false
    resources:
      - names: [client]
        compress: false
trusted_key_servers: []
rc_message:
  per_second: 100
  burst_count: 100
rc_login:
  address: {per_second: 100, burst_count: 100}
  account: {per_second: 100, burst_count: 100}
  failed_attempts: {per_second: 100, burst_count: 100}
EOF

    "$DIRECTORY/venv/bin/python" -m synapse.app.homeserver \
        --config-path "$DIRECTORY/homeserver.yaml" \
        --config-path "$DIRECTORY/overrides.yaml" \
        --daemonize

    for _ in $(seq 60); do
        curl -fsS "$HOMESERVER_URL/_matrix/client/versions" > /dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS "$HOMESERVER_URL/_matrix/client/versions" > /dev/null

    local password
    password="$(openssl rand -hex 16)"
    register "$USERNAME" "$password"
    register "$INVITEE" "$(openssl rand -hex 16)"

    local token
    token="$(curl -fsS -X POST "$HOMESERVER_URL/_matrix/client/v3/login" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg user "$USERNAME" --arg password "$password" \
            '{type: "m.login.password", identifier: {type: "m.id.user", user: $user}, password: $password}')" \
        | jq -r .access_token)"

    # The member list opens its manage sheet only for other members, and lists pending invites first.
    curl -fsS -X POST "$HOMESERVER_URL/_matrix/client/v3/createRoom" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg name "$ROOM_NAME" --arg invitee "@$INVITEE:$SERVER_NAME" \
            '{name: $name, preset: "private_chat", invite: [$invitee],
              initial_state: [{type: "m.room.encryption", state_key: "", content: {algorithm: "m.megolm.v1.aes-sha2"}}]}')" \
        > /dev/null

    curl -fsS -X POST "$HOMESERVER_URL/_matrix/client/v3/logout" -H "Authorization: Bearer $token" > /dev/null

    {
        echo "INTEGRATION_TESTS_HOST=$HOMESERVER_URL"
        echo "INTEGRATION_TESTS_USERNAME=$USERNAME"
        echo "INTEGRATION_TESTS_PASSWORD=$password"
    } >> "$GITHUB_ENV"
}

register() {
    "$DIRECTORY/venv/bin/register_new_matrix_user" \
        --user "$1" \
        --password "$2" \
        --no-admin \
        --config "$DIRECTORY/homeserver.yaml" \
        "$HOMESERVER_URL"
}

stop() {
    if [ -f "$DIRECTORY/homeserver.pid" ]; then
        kill "$(cat "$DIRECTORY/homeserver.pid")" || true
    fi
    rm -rf "$DIRECTORY"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    *) echo "Usage: $0 start|stop" >&2; exit 1 ;;
esac
