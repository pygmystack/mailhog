#!/usr/bin/env bats
# Image structure tests — verify the binary, exposed ports, entrypoint, and
# working directory baked into the MailHog image.  Tests run ephemeral
# containers and do not require a long-running process.

bats_require_minimum_version 1.5.0

IMAGE="${IMAGE_NAME:-pygmystack/mailhog:test}"

# ---------------------------------------------------------------------------
# Binary
# ---------------------------------------------------------------------------

@test "MailHog binary is present at /bin/MailHog" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'test -f /bin/MailHog'
    [ "$status" -eq 0 ]
}

@test "MailHog binary is executable" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'test -x /bin/MailHog'
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Exposed ports (image metadata)
# ---------------------------------------------------------------------------

@test "image declares SMTP port 1025 as exposed" {
    run docker inspect --format='{{json .Config.ExposedPorts}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1025" ]]
}

@test "image declares HTTP port 8025 as exposed" {
    run docker inspect --format='{{json .Config.ExposedPorts}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "8025" ]]
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

@test "image entrypoint is MailHog" {
    run docker inspect --format='{{json .Config.Entrypoint}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "MailHog" ]]
}

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------

@test "image working directory is /bin" {
    run docker inspect --format='{{.Config.WorkingDir}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [ "$output" = "/bin" ]
}
