#!/usr/bin/env bats
# Runtime tests — start a Mailpit container and exercise SMTP reception and
# the HTTP API.
#
# A dedicated container is started once in setup_file() and torn down in
# teardown_file().  The container is placed on a private Docker network so
# that Lagoon-style PHP container tests can reach Mailpit via the well-known
# hostname "amazeeio-mailpit" (matching the alias used by Lagoon's 50-ssmtp.sh
# entrypoint).  Host-mapped ports are used for curl-based SMTP sends and
# API assertions so that the tests work on both Linux and macOS (Docker
# Desktop).
#
# Tests are ordered intentionally: the empty-mailbox assertions run before
# any email-send tests; deletion tests run last.

bats_require_minimum_version 1.5.0

IMAGE="${IMAGE_NAME:-pygmystack/mailhog:test}"
PHP_FPM_IMAGE="${PHP_FPM_IMAGE:-uselagoon/php-8.5-fpm}"

# Populated in setup() from files written by setup_file().
MAILPIT_CONTAINER=""
MAILPIT_NETWORK=""
MAILPIT_ISOLATED_NETWORK=""
SMTP_PORT=""
HTTP_PORT=""

# ---------------------------------------------------------------------------
# File-level setup / teardown
# ---------------------------------------------------------------------------

setup_file() {
    local suffix
    suffix="$(openssl rand -hex 4)"
    echo "${suffix}" > "${BATS_SUITE_TMPDIR}/.suffix"

    local container="mailpit-bats-test-${suffix}"
    local network="mailpit-bats-net-${suffix}"

    # Pre-pull the Lagoon PHP image so it is locally cached before any test
    # runs.  Without this, the first test to use the image would trigger an
    # inline pull, and the short default ssmtp/sendmail connection timeout
    # could expire against the still-starting container.
    docker pull "${PHP_FPM_IMAGE}"

    # Clean up any leftovers from a previous (failed) run.
    docker rm -f "${container}" 2>/dev/null || true
    docker network rm "${network}" 2>/dev/null || true

    # Create a dedicated network so the Lagoon-style PHP container tests can
    # reach Mailpit via the "amazeeio-mailpit" hostname without any extra setup.
    docker network create "${network}"
    echo "${network}" > "${BATS_SUITE_TMPDIR}/.network"

    # Create an isolated (--internal) network for the host.docker.internal
    # tests.  An internal network has no host routing, so the
    # `nc -z -w 1 172.17.0.1 1025` probe in 50-ssmtp.sh reliably fails even
    # when a pygmy Mailpit is listening on the host machine.  This ensures the
    # host.docker.internal branch is the first one that can succeed.
    local isolated_network
    isolated_network="${network}-isolated"
    docker network create --internal "${isolated_network}"
    echo "${isolated_network}" > "${BATS_SUITE_TMPDIR}/.isolated_network"

    # Start Mailpit with auto-assigned host ports and on the test network.
    docker run -d \
        --name "${container}" \
        --network "${network}" \
        --network-alias "amazeeio-mailpit" \
        -p 1025 \
        -p 80 \
        "${IMAGE}"

    # Also connect Mailpit to the isolated network so that host.docker.internal
    # tests can reach it without going via the host.
    docker network connect --alias amazeeio-mailpit "${isolated_network}" "${container}"

    # Discover the host-mapped ports (handles both 0.0.0.0:PORT and [::]:PORT).
    local smtp_port http_port
    smtp_port="$(docker port "${container}" 1025/tcp | grep -oE '[0-9]+$' | head -1)"
    http_port="$(docker port "${container}" 80/tcp | grep -oE '[0-9]+$' | head -1)"
    echo "${smtp_port}" > "${BATS_SUITE_TMPDIR}/.smtp_port"
    echo "${http_port}"  > "${BATS_SUITE_TMPDIR}/.http_port"

    # Wait up to 30 seconds for the HTTP API to become ready.
    local max_wait=30 waited=0
    until curl -sf "http://localhost:${http_port}/api/v1/messages" >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ "${waited}" -ge "${max_wait}" ]; then
            echo "# Timed out waiting for Mailpit HTTP API on port ${http_port}" >&3
            docker logs "${container}" >&3 2>&3
            return 1
        fi
    done
}

teardown_file() {
    local suffix network isolated_network
    suffix="$(cat "${BATS_SUITE_TMPDIR}/.suffix" 2>/dev/null || true)"
    network="$(cat "${BATS_SUITE_TMPDIR}/.network" 2>/dev/null || true)"
    isolated_network="$(cat "${BATS_SUITE_TMPDIR}/.isolated_network" 2>/dev/null || true)"
    docker rm -f "mailpit-bats-test-${suffix}" 2>/dev/null || true
    docker network rm "${isolated_network}" 2>/dev/null || true
    docker network rm "${network}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Per-test setup — restore variables from the files written by setup_file().
# ---------------------------------------------------------------------------

setup() {
    local suffix
    suffix="$(cat "${BATS_SUITE_TMPDIR}/.suffix" 2>/dev/null || true)"
    MAILPIT_CONTAINER="mailpit-bats-test-${suffix}"
    MAILPIT_NETWORK="$(cat "${BATS_SUITE_TMPDIR}/.network" 2>/dev/null || true)"
    MAILPIT_ISOLATED_NETWORK="$(cat "${BATS_SUITE_TMPDIR}/.isolated_network" 2>/dev/null || true)"
    SMTP_PORT="$(cat "${BATS_SUITE_TMPDIR}/.smtp_port" 2>/dev/null || true)"
    HTTP_PORT="$(cat "${BATS_SUITE_TMPDIR}/.http_port"  2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# send_test_email FROM TO SUBJECT BODY
# Sends an RFC 2822 email to the running Mailpit over SMTP using curl.
send_test_email() {
    local from="${1:-sender@example.com}"
    local to="${2:-recipient@example.com}"
    local subject="${3:-BATS Test Email}"
    local body="${4:-This is a test email sent by BATS.}"

    curl --silent --show-error \
        --url "smtp://localhost:${SMTP_PORT}" \
        --mail-from "${from}" \
        --mail-rcpt "${to}" \
        --upload-file - <<EOF
From: ${from}
To: ${to}
Subject: ${subject}

${body}
EOF
}

# delete_all_messages — purges every message from Mailpit via its API.
delete_all_messages() {
    curl -sf -X DELETE "http://localhost:${HTTP_PORT}/api/v1/messages" >/dev/null
}

# message_total — returns the integer value of the "total" field from the v1 API.
message_total() {
    curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages" \
        | grep -o '"total":[0-9]*' | cut -d: -f2
}

# ---------------------------------------------------------------------------
# Container lifecycle
# ---------------------------------------------------------------------------

@test "container is running" {
    run docker inspect --format='{{.State.Status}}' "${MAILPIT_CONTAINER}"
    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
}

@test "mailpit process is running inside the container" {
    run docker exec "${MAILPIT_CONTAINER}" sh -c 'ps | grep "[m]ailpit"'
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# HTTP UI and API
# ---------------------------------------------------------------------------

@test "Mailpit web UI responds with HTML containing 'Mailpit'" {
    run curl -sf "http://localhost:${HTTP_PORT}/"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Mailpit" ]]
}

@test "Mailpit API v1 messages endpoint returns a JSON object with a 'total' field" {
    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ '"total"' ]]
}

# ---------------------------------------------------------------------------
# Email reception — empty state
# ---------------------------------------------------------------------------

@test "message count is zero before any email is sent" {
    delete_all_messages
    local total
    total="$(message_total)"
    [ "${total}" = "0" ]
}

# ---------------------------------------------------------------------------
# Email reception — sending via SMTP
# ---------------------------------------------------------------------------

@test "an email sent via SMTP is captured by Mailpit" {
    delete_all_messages
    send_test_email \
        "sender@example.com" \
        "recipient@example.com" \
        "BATS Test Email" \
        "Hello from BATS."
    local total
    total="$(message_total)"
    [ "${total}" = "1" ]
}

@test "captured email has the correct From address" {
    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "sender@example.com" ]]
}

@test "captured email has the correct To address" {
    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "recipient@example.com" ]]
}

@test "captured email has the correct Subject" {
    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "BATS Test Email" ]]
}

@test "captured email body contains expected content" {
    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Hello from BATS" ]]
}

# ---------------------------------------------------------------------------
# Email deletion
# ---------------------------------------------------------------------------

@test "all messages can be deleted via the Mailpit API" {
    run curl -sf -X DELETE "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
}

@test "message count is zero after deleting all messages" {
    local total
    total="$(message_total)"
    [ "${total}" = "0" ]
}

# ---------------------------------------------------------------------------
# Multiple messages
# ---------------------------------------------------------------------------

@test "multiple emails sent via SMTP all appear in Mailpit" {
    delete_all_messages
    send_test_email "a@example.com" "x@example.com" "Email One"   "Body one."
    send_test_email "b@example.com" "y@example.com" "Email Two"   "Body two."
    send_test_email "c@example.com" "z@example.com" "Email Three" "Body three."
    local total
    total="$(message_total)"
    [ "${total}" = "3" ]
    delete_all_messages
}

# ---------------------------------------------------------------------------
# Lagoon-style email send — simulates the 50-ssmtp.sh entrypoint
#
# Uses the real uselagoon/php-8.5-fpm image with ssmtp installed and the
# 50-ssmtp.sh entrypoint at /lagoon/entrypoints/50-ssmtp.sh.  The script is
# dot-sourced so its `return` statements are handled correctly, then the
# ssmtp sendmail binary delivers the message — exactly as a live Lagoon PHP
# container would when SSMTP_MAILHUB is set by an operator.
# ---------------------------------------------------------------------------

@test "email sent via Lagoon PHP container (ssmtp) is captured by Mailpit" {
    delete_all_messages

    # Pass SSMTP_MAILHUB so 50-ssmtp.sh writes mailhub=amazeeio-mailpit:1025
    # into /etc/ssmtp/ssmtp.conf, then send via the real ssmtp sendmail binary.
    run docker run --rm \
        --network "${MAILPIT_NETWORK}" \
        -e "SSMTP_MAILHUB=amazeeio-mailpit:1025" \
        --entrypoint sh \
        "${PHP_FPM_IMAGE}" -euc '
            . /lagoon/entrypoints/50-ssmtp.sh
            printf "To: dev@example.com\nFrom: lagoon-test@example.com\nSubject: Lagoon BATS Test\n\nSent via ssmtp as Lagoon would.\n" \
                | sendmail -t
        '
    [ "$status" -eq 0 ]

    # Verify the message arrived in Mailpit.
    local total
    total="$(message_total)"
    [ "${total}" -ge "1" ]

    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Lagoon BATS Test" ]]

    delete_all_messages
}

# ---------------------------------------------------------------------------
# SSMTP_MAILHUB env var — simulates lines 20-21 of 50-ssmtp.sh
#
# When SSMTP_MAILHUB is explicitly set, Lagoon's 50-ssmtp.sh writes:
#   mailhub=${SSMTP_MAILHUB}
# directly into /etc/ssmtp/ssmtp.conf and skips all auto-detection.
# These tests verify that a client honouring SSMTP_MAILHUB successfully
# delivers mail to Mailpit using the configured hub value.
# ---------------------------------------------------------------------------

@test "email sent with SSMTP_MAILHUB set to 'amazeeio-mailpit:1025' is captured by Mailpit" {
    delete_all_messages

    # The real 50-ssmtp.sh writes "mailhub=${SSMTP_MAILHUB}" into
    # /etc/ssmtp/ssmtp.conf when SSMTP_MAILHUB is set (lines 20-21).  Dot-
    # source so `return` is handled correctly, then send via ssmtp sendmail.
    run docker run --rm \
        --network "${MAILPIT_NETWORK}" \
        -e "SSMTP_MAILHUB=amazeeio-mailpit:1025" \
        --entrypoint sh \
        "${PHP_FPM_IMAGE}" -euc '
            . /lagoon/entrypoints/50-ssmtp.sh
            printf "To: dev@example.com\nFrom: ssmtp-mailhub-test@example.com\nSubject: SSMTP_MAILHUB Test\n\nSent via SSMTP_MAILHUB.\n" \
                | sendmail -t
        '
    [ "$status" -eq 0 ]

    local total
    total="$(message_total)"
    [ "${total}" -ge "1" ]

    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SSMTP_MAILHUB Test" ]]

    delete_all_messages
}

@test "email sent with SSMTP_MAILHUB overrides auto-detection and reaches Mailpit" {
    delete_all_messages

    # Confirms the override semantics: SSMTP_MAILHUB is the first branch in
    # 50-ssmtp.sh's if/elif chain so it short-circuits all auto-detection
    # (172.17.0.1, host.docker.internal, LAGOON_PROJECT) regardless of what
    # else might be reachable on the network.
    run docker run --rm \
        --network "${MAILPIT_NETWORK}" \
        -e "SSMTP_MAILHUB=amazeeio-mailpit:1025" \
        --entrypoint sh \
        "${PHP_FPM_IMAGE}" -euc '
            . /lagoon/entrypoints/50-ssmtp.sh
            printf "To: dev@example.com\nFrom: override-test@example.com\nSubject: SSMTP_MAILHUB Override Test\n\nSMTP_MAILHUB takes priority.\n" \
                | sendmail -t
        '
    [ "$status" -eq 0 ]

    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "SSMTP_MAILHUB Override Test" ]]

    delete_all_messages
}

# ---------------------------------------------------------------------------
# host.docker.internal — simulates lines 26-29 of 50-ssmtp.sh
#
# When neither SSMTP_MAILHUB nor 172.17.0.1:1025 is available, Lagoon's
# 50-ssmtp.sh tries `nc -z -w 1 host.docker.internal 1025`.  If that
# succeeds it writes "mailhub=host.docker.internal:1025" into ssmtp.conf.
#
# An --internal Docker network is used here so that the 172.17.0.1:1025 nc
# probe reliably fails even when a pygmy Mailpit is listening on the host
# machine (internal networks have no host routing).  The Mailpit container is
# connected to both the regular and the isolated network; its IP on the isolated
# network is injected as host.docker.internal via --add-host so that the nc
# probe and ssmtp sendmail both resolve to the BATS Mailpit.
# ---------------------------------------------------------------------------

@test "email sent via host.docker.internal route is captured by Mailpit" {
    delete_all_messages

    # Use the isolated (--internal) network so that the nc probe to
    # 172.17.0.1:1025 in 50-ssmtp.sh reliably fails — even when a host-level
    # pygmy Mailpit is running — and the host.docker.internal branch becomes
    # the first probe to succeed.  The Mailpit IP on the isolated network is
    # injected via --add-host so that nc and ssmtp both resolve it correctly.
    local mailpit_isolated_ip
    mailpit_isolated_ip="$(docker inspect \
        --format="{{(index .NetworkSettings.Networks \"${MAILPIT_ISOLATED_NETWORK}\").IPAddress}}" \
        "${MAILPIT_CONTAINER}")"

    run docker run --rm \
        --network "${MAILPIT_ISOLATED_NETWORK}" \
        --add-host "host.docker.internal:${mailpit_isolated_ip}" \
        --entrypoint sh \
        "${PHP_FPM_IMAGE}" -euc '
            . /lagoon/entrypoints/50-ssmtp.sh
            printf "To: dev@example.com\nFrom: hdi-test@example.com\nSubject: host.docker.internal Test\n\nSent via host.docker.internal.\n" \
                | sendmail -t
        '
    [ "$status" -eq 0 ]

    local total
    total="$(message_total)"
    [ "${total}" -ge "1" ]

    run curl -sf "http://localhost:${HTTP_PORT}/api/v1/messages"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "host.docker.internal Test" ]]

    delete_all_messages
}

@test "nc probe to host.docker.internal:1025 succeeds when Mailpit is reachable" {
    # Verify the nc connectivity check itself — the condition that 50-ssmtp.sh
    # evaluates before writing mailhub=host.docker.internal:1025.
    local mailpit_isolated_ip
    mailpit_isolated_ip="$(docker inspect \
        --format="{{(index .NetworkSettings.Networks \"${MAILPIT_ISOLATED_NETWORK}\").IPAddress}}" \
        "${MAILPIT_CONTAINER}")"

    run docker run --rm \
        --network "${MAILPIT_ISOLATED_NETWORK}" \
        --add-host "host.docker.internal:${mailpit_isolated_ip}" \
        --entrypoint sh \
        "${PHP_FPM_IMAGE}" -euc 'nc -z -w 1 host.docker.internal 1025'
    [ "$status" -eq 0 ]
}
