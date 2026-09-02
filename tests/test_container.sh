#!/usr/bin/env bash

set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE_FILE="${REPO_DIR}/tests/fixtures/smoke-config.yaml"
IMAGE_TAG="${1:-}"
CALLER_SAFE_PATH="${2:-/tmp/clash4docker-ci-safe-$$-${RANDOM}}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-90}"
CONTAINER_ID=""
TEST_DIR=""

die() {
    printf 'container smoke failed: %s\n' "$*" >&2
    exit 1
}

if [ -z "${IMAGE_TAG}" ]; then
    die "usage: $0 IMAGE_TAG [CALLER_SAFE_PATH]"
fi

if ! command -v docker >/dev/null 2>&1; then
    die "docker is required"
fi

if [ ! -f "${FIXTURE_FILE}" ]; then
    die "fixture not found: ${FIXTURE_FILE}"
fi

case "${CALLER_SAFE_PATH}" in
    ""|*:*|*[[:space:]]*)
        die "CALLER_SAFE_PATH must be a non-empty path without colons or whitespace"
        ;;
esac

case "${HEALTH_TIMEOUT_SECONDS}" in
    ''|*[!0-9]*|0)
        die "HEALTH_TIMEOUT_SECONDS must be a positive integer"
        ;;
esac

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    die "image is not available locally: ${IMAGE_TAG}"
fi

TEST_DIR=$(mktemp -d "${REPO_DIR}/.clash4docker-ci.XXXXXX")
CONFIG_DIR="${TEST_DIR}/config"
mkdir -p "${CONFIG_DIR}"
cp "${FIXTURE_FILE}" "${CONFIG_DIR}/config.yaml"

CONTAINER_NAME="clash4docker-ci-smoke-$(date +%s)-$$-${RANDOM}"

print_diagnostics() {
    printf '\n--- docker inspect (%s) ---\n' "${CONTAINER_NAME}" >&2
    docker inspect "${CONTAINER_ID}" >&2 || true
    printf '\n--- docker logs (%s) ---\n' "${CONTAINER_NAME}" >&2
    docker logs "${CONTAINER_ID}" >&2 || true
}

cleanup() {
    local status=$?
    trap - EXIT

    if [ "${status}" -ne 0 ] && [ -n "${CONTAINER_ID}" ]; then
        print_diagnostics
    fi

    if [ -n "${CONTAINER_ID}" ]; then
        if ! docker rm --force "${CONTAINER_ID}" >/dev/null 2>&1; then
            printf 'container smoke cleanup failed; container may remain: %s\n' "${CONTAINER_NAME}" >&2
            [ "${status}" -eq 0 ] && status=1
        fi
    fi

    if [ -n "${TEST_DIR}" ]; then
        rm -rf "${TEST_DIR}"
    fi

    exit "${status}"
}
trap cleanup EXIT

CONTAINER_ID=$(docker create \
    --name "${CONTAINER_NAME}" \
    --network none \
    --env "SAFE_PATHS=${CALLER_SAFE_PATH}" \
    --env HTTP_PROXY= \
    --env HTTPS_PROXY= \
    --env ALL_PROXY= \
    --env http_proxy= \
    --env https_proxy= \
    --env all_proxy= \
    --env 'NO_PROXY=*' \
    --env 'no_proxy=*' \
    --env SUB_URL= \
    --env SECRET= \
    --env SUB_CRON= \
    --env TUN_ENABLED= \
    --env DNS_OVERRIDE= \
    --mount "type=bind,source=${CONFIG_DIR},target=/root/.config/mihomo" \
    "${IMAGE_TAG}")

docker start "${CONTAINER_ID}" >/dev/null

deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
health_status=""
while (( SECONDS < deadline )); do
    health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "${CONTAINER_ID}" 2>/dev/null || true)
    case "${health_status}" in
        healthy)
            break
            ;;
        unhealthy)
            die "container healthcheck reported unhealthy"
            ;;
        missing)
            die "image does not define a healthcheck"
            ;;
    esac

    container_state=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_ID}" 2>/dev/null || true)
    case "${container_state}" in
        exited|dead)
            die "container exited before becoming healthy (state: ${container_state})"
            ;;
    esac
    sleep 2
done

if [ "${health_status}" != "healthy" ]; then
    die "healthcheck timed out after ${HEALTH_TIMEOUT_SECONDS}s (last status: ${health_status:-unknown})"
fi

version_response=$(docker exec "${CONTAINER_ID}" sh -ec '
    response=$(wget -q -O - http://127.0.0.1:9090/version)
    [ -n "${response}" ]
    printf "%s" "${response}"
')
if [ -z "${version_response}" ]; then
    die "/version returned an empty response"
fi
if ! printf '%s\n' "${version_response}" | grep -Eqi 'version|mihomo'; then
    die "/version response does not contain version information: ${version_response}"
fi
printf '/version response: %s\n' "${version_response}"

ui_response=$(docker exec "${CONTAINER_ID}" sh -ec '
    response=$(wget -q -O - http://127.0.0.1:9090/ui/)
    [ -n "${response}" ]
    printf "%s" "${response}"
')
if [ -z "${ui_response}" ]; then
    die "/ui/ returned an empty response"
fi
printf '/ui/ is reachable\n'

process_env=$(docker exec "${CONTAINER_ID}" sh -ec '
    pid=$(cat /var/run/mihomo.pid)
    case "${pid}" in
        ""|*[!0-9]*)
            echo "invalid mihomo pid: ${pid}" >&2
            exit 1
            ;;
    esac
    printf "PID=%s\n" "${pid}"
    tr "\\000" "\\n" < "/proc/${pid}/environ"
')
safe_paths=$(printf '%s\n' "${process_env}" | sed -n 's/^SAFE_PATHS=//p')
if [ -z "${safe_paths}" ]; then
    die "mihomo process environment does not contain SAFE_PATHS"
fi

has_safe_path_entry() {
    local value="$1"
    local expected="$2"
    local entry

    while IFS= read -r entry; do
        if [ "${entry}" = "${expected}" ]; then
            return 0
        fi
    done < <(printf '%s\n' "${value}" | tr ':' '\n')
    return 1
}

if ! has_safe_path_entry "${safe_paths}" "${CALLER_SAFE_PATH}"; then
    die "SAFE_PATHS is missing caller path as an independent entry: ${safe_paths}"
fi
printf 'SAFE_PATHS preserves caller entry: %s\n' "${CALLER_SAFE_PATH}"
printf 'container smoke passed: %s\n' "${IMAGE_TAG}"
