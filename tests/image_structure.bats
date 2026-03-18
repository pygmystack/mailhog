#!/usr/bin/env bats
# Image structure tests — verify the binary, exposed ports, entrypoint, and
# working directory baked into the Mailpit image.  Tests run ephemeral
# containers and do not require a long-running process.

bats_require_minimum_version 1.5.0

IMAGE="${IMAGE_NAME:-pygmystack/mailhog:test}"

# ---------------------------------------------------------------------------
# Binary
# ---------------------------------------------------------------------------

@test "mailpit binary is present at /mailpit" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'test -f /mailpit'
    [ "$status" -eq 0 ]
}

@test "mailpit binary is executable" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'test -x /mailpit'
    [ "$status" -eq 0 ]
}

@test "/bin/MailHog symlink points to /mailpit" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'test -L /bin/MailHog'
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

@test "image declares HTTP port 80 as exposed" {
    run docker inspect --format='{{json .Config.ExposedPorts}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "\"80" ]]
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

@test "image entrypoint is mailpit" {
    run docker inspect --format='{{json .Config.Entrypoint}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "mailpit" ]]
}

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------

@test "image working directory is /" {
    run docker inspect --format='{{.Config.WorkingDir}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [ "$output" = "/" ]
}
