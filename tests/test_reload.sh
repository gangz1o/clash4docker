#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${REPO_DIR}/start.sh"

assert_arg() {
    local expected="$1"
    local arg
    for arg in "${CURL_ARGS[@]}"; do
        [ "${arg}" = "${expected}" ] && return 0
    done
    return 1
}

assert_no_auth_header() {
    local arg
    for arg in "${CURL_ARGS[@]}"; do
        [[ "${arg}" == Authorization:* ]] && return 1
    done
    return 0
}

CURL_STATUS=0
CURL_CALLS=0
CURL_FAIL_ONCE=false
CURL_ARGS=()
curl() {
    CURL_CALLS=$((CURL_CALLS + 1))
    CURL_ARGS=("$@")
    if [ "${CURL_FAIL_ONCE}" = "true" ] && [ "${CURL_CALLS}" -eq 1 ]; then
        return 1
    fi
    return "${CURL_STATUS}"
}
sleep() { return 0; }

SECRET="dashboard-secret"
reload_mihomo_config
assert_arg "Authorization: Bearer dashboard-secret"
assert_arg "http://127.0.0.1:9090/configs?force=true"
assert_arg '{"path":"","payload":""}'
assert_arg "PUT"
assert_arg "Content-Type: application/json"
assert_arg "--noproxy"
assert_arg "*"

SECRET=""
CURL_ARGS=()
reload_mihomo_config
assert_no_auth_header

CURL_STATUS=1
CURL_CALLS=0
if reload_mihomo_config; then
    echo "curl 失败时 reload_mihomo_config 不应返回成功" >&2
    exit 1
fi
[ "${CURL_CALLS}" -eq 2 ]

CURL_STATUS=0
CURL_CALLS=0
CURL_FAIL_ONCE=true
reload_mihomo_config
[ "${CURL_CALLS}" -eq 2 ]
CURL_FAIL_ONCE=false

CURL_STATUS=0
CURL_ARGS=()
check_mihomo_controller "dashboard-secret"
assert_arg "http://127.0.0.1:9090/version"
assert_arg "Authorization: Bearer dashboard-secret"
assert_arg "--noproxy"

CURL_ARGS=()
check_mihomo_controller ""
assert_no_auth_header

CURL_STATUS=1
if check_mihomo_controller "dashboard-secret"; then
    echo "curl 失败时 check_mihomo_controller 不应返回成功" >&2
    exit 1
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT
CONFIG_FILE="${TEST_DIR}/config.yaml"
UPDATE_LOCK_FILE="${TEST_DIR}/update.lock"
FLOCK_STATUS=0
flock() { return "${FLOCK_STATUS}"; }
cat > "${CONFIG_FILE}" <<'EOF'
secret: 'controller-secret'
mixed-port: 7890
routing-mark: 1
proxies: []
EOF

DOWNLOAD_CONTENT="secret: 'next-secret'
mixed-port: 7890
routing-mark: 2
proxies: []"
DOWNLOAD_CALLS=0
download_subscription() {
    DOWNLOAD_CALLS=$((DOWNLOAD_CALLS + 1))
    printf '%s\n' "${DOWNLOAD_CONTENT}" > "${CONFIG_FILE}"
}
update_allow_lan() { return 0; }
update_authentication() { return 0; }
ensure_unified_delay_and_tcp_concurrent() { return 0; }
inject_tun() { return 0; }
inject_dns() { return 0; }
ensure_external_controller() { return 0; }
HOOK_STATUS=0
run_post_subscription_hooks() { return "${HOOK_STATUS}"; }
CONTROLLER_CHECK_SECRET=""
CONTROLLER_CHECK_CALLS=0
CONTROLLER_CHECK_STATUS=0
check_mihomo_controller() {
    CONTROLLER_CHECK_CALLS=$((CONTROLLER_CHECK_CALLS + 1))
    CONTROLLER_CHECK_SECRET="${1:-}"
    return "${CONTROLLER_CHECK_STATUS}"
}

RELOAD_CALLS=0
RESTART_CALLED=false
RELOAD_FIRST_STATUS=0
RELOAD_LATER_STATUS=0
RELOAD_SECRET=""
reload_mihomo_config() {
    RELOAD_CALLS=$((RELOAD_CALLS + 1))
    RELOAD_SECRET="${1:-}"
    if [ "${RELOAD_CALLS}" -eq 1 ]; then
        return "${RELOAD_FIRST_STATUS}"
    fi
    return "${RELOAD_LATER_STATUS}"
}
restart_mihomo() { RESTART_CALLED=true; }

SUB_URL="https://example.com/subscription"
SECRET="controller-secret"
ALLOW_LAN=""
AUTHENTICATION=""
TUN_ENABLED=""
DNS_OVERRIDE=""

update_subscription
[ "${RELOAD_CALLS}" -eq 1 ]
[ "${RELOAD_SECRET}" = "controller-secret" ]
[ "${CONTROLLER_CHECK_SECRET}" = "controller-secret" ]
[ "${RESTART_CALLED}" = "false" ]
grep -q "controller-secret" "${CONFIG_FILE}"
grep -q "routing-mark: 2" "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'EOF'
secret: 'controller-secret'
mixed-port: 7890
routing-mark: 1
proxies: []
EOF
RELOAD_CALLS=0
RESTART_CALLED=false
RELOAD_FIRST_STATUS=1
RELOAD_LATER_STATUS=0

if update_subscription; then
    echo "热加载失败时 update_subscription 不应返回成功" >&2
    exit 1
fi
[ "${RELOAD_CALLS}" -eq 2 ]
[ "${RESTART_CALLED}" = "false" ]
grep -q "controller-secret" "${CONFIG_FILE}"
grep -q "routing-mark: 1" "${CONFIG_FILE}"
! grep -q "routing-mark: 2" "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'EOF'
secret: ''
mixed-port: 7890
routing-mark: 1
proxies: []
EOF
SECRET=""
RELOAD_CALLS=0
RELOAD_FIRST_STATUS=0
RELOAD_LATER_STATUS=0
CONTROLLER_CHECK_SECRET="not-empty"
update_subscription
[ "${CONTROLLER_CHECK_SECRET}" = "" ]
[ "${RELOAD_SECRET}" = "" ]
grep -q "^secret: ''$" "${CONFIG_FILE}"
[ "${RESTART_CALLED}" = "false" ]

ORIGINAL_SED_INPLACE=$(declare -f sed_inplace)
cat > "${CONFIG_FILE}" <<'EOF'
secret: 'controller-secret'
mixed-port: 7890
routing-mark: 1
proxies: []
EOF
SECRET="controller-secret"
RELOAD_CALLS=0
sed_inplace() { return 1; }
if update_subscription; then
    echo "控制通道写入失败时 update_subscription 不应返回成功" >&2
    exit 1
fi
[ "${RELOAD_CALLS}" -eq 0 ]
grep -q "routing-mark: 1" "${CONFIG_FILE}"
eval "${ORIGINAL_SED_INPLACE}"

cp "${CONFIG_FILE}" "${TEST_DIR}/before-controller-failure.yaml"
DOWNLOAD_CALLS_BEFORE=${DOWNLOAD_CALLS}
CONTROLLER_CHECK_STATUS=1
if update_subscription; then
    echo "Controller 探测失败时 update_subscription 不应返回成功" >&2
    exit 1
fi
[ "${DOWNLOAD_CALLS}" -eq "${DOWNLOAD_CALLS_BEFORE}" ]
cmp "${TEST_DIR}/before-controller-failure.yaml" "${CONFIG_FILE}"
CONTROLLER_CHECK_STATUS=0

cat > "${CONFIG_FILE}" <<'EOF'
secret: 'controller-secret'
mixed-port: 7890
routing-mark: 1
proxies: []
EOF
HOOK_STATUS=1
RELOAD_CALLS=0
if update_subscription; then
    echo "Hook 失败时 update_subscription 不应返回成功" >&2
    exit 1
fi
[ "${RELOAD_CALLS}" -eq 0 ]
grep -q "routing-mark: 1" "${CONFIG_FILE}"
HOOK_STATUS=0

RELOAD_CALLS=0
DOWNLOAD_CALLS_BEFORE=${DOWNLOAD_CALLS}
CONTROLLER_CHECK_CALLS_BEFORE=${CONTROLLER_CHECK_CALLS}
cp "${CONFIG_FILE}" "${TEST_DIR}/before-lock.yaml"
FLOCK_STATUS=1
if update_subscription; then
    echo "已有更新锁时 update_subscription 不应返回成功" >&2
    exit 1
fi
[ "${RELOAD_CALLS}" -eq 0 ]
[ "${DOWNLOAD_CALLS}" -eq "${DOWNLOAD_CALLS_BEFORE}" ]
[ "${CONTROLLER_CHECK_CALLS}" -eq "${CONTROLLER_CHECK_CALLS_BEFORE}" ]
cmp "${TEST_DIR}/before-lock.yaml" "${CONFIG_FILE}"
FLOCK_STATUS=0
RELOAD_FIRST_STATUS=0
if ! update_subscription; then
    echo "释放文件锁后订阅更新应恢复执行" >&2
    exit 1
fi

echo "配置热加载测试通过"
