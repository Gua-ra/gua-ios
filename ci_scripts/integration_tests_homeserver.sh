#!/bin/bash

# A throwaway Synapse for the integration tests, bound to localhost, with the user and the room the tests use.
# Usage: integration_tests_homeserver.sh start|stop

set -euo pipefail

# The last Synapse with macOS wheels. It fails to import with prometheus-client 0.24 or later.
SYNAPSE_VERSION="1.143.0"
PROMETHEUS_CLIENT_VERSION="0.23.1"
HOMESERVER_URL="http://127.0.0.1:8008"
SERVER_NAME="localhost"
USERNAME="integration-tests"
ROOM_OWNER="room-owner"
INVITEE="invitee"
ROOM_NAME="Element X iOS Integration Tests"
DIRECTORY="${RUNNER_TEMP:-/tmp}/integration-tests-homeserver"

start() {
    mkdir -p "$DIRECTORY"
    # The generated logging config writes homeserver.log to the working directory.
    cd "$DIRECTORY"
    python3 -m venv "$DIRECTORY/venv"
    # register_new_matrix_user needs requests, which Synapse doesn't install.
    "$DIRECTORY/venv/bin/pip" install --quiet "matrix-synapse==$SYNAPSE_VERSION" "prometheus-client==$PROMETHEUS_CLIENT_VERSION" requests

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

    local password owner_password
    password="$(openssl rand -hex 16)"
    owner_password="$(openssl rand -hex 16)"
    register "$USERNAME" "$password"
    register "$ROOM_OWNER" "$owner_password"
    register "$INVITEE" "$(openssl rand -hex 16)"

    # The test user must not be a room admin: admins get a Members/Banned picker above the member list.
    # The member list opens its manage sheet only for other members and lists pending invites first.
    # The chat list hides rooms with no messages and at most two members.
    local owner_token room_id
    owner_token="$(login "$ROOM_OWNER" "$owner_password")"
    room_id="$(curl -fsS -X POST "$HOMESERVER_URL/_matrix/client/v3/createRoom" \
        -H "Authorization: Bearer $owner_token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg name "$ROOM_NAME" --arg server "$SERVER_NAME" --arg user "$USERNAME" --arg invitee "$INVITEE" \
            '{name: $name, preset: "private_chat", invite: ["@\($user):\($server)", "@\($invitee):\($server)"],
              initial_state: [{type: "m.room.encryption", state_key: "", content: {algorithm: "m.megolm.v1.aes-sha2"}}]}')" \
        | jq -r .room_id)"

    local token
    token="$(login "$USERNAME" "$password")"
    curl -fsS -X POST "$HOMESERVER_URL/_matrix/client/v3/rooms/$(jq -rn --arg id "$room_id" '$id | @uri')/join" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d '{}' \
        > /dev/null

    logout "$token"
    logout "$owner_token"

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

login() {
    curl -fsS -X POST "$HOMESERVER_URL/_matrix/client/v3/login" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg user "$1" --arg password "$2" \
            '{type: "m.login.password", identifier: {type: "m.id.user", user: $user}, password: $password}')" \
        | jq -r .access_token
}

logout() {
    curl -fsS -X POST "$HOMESERVER_URL/_matrix/client/v3/logout" -H "Authorization: Bearer $1" > /dev/null
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
