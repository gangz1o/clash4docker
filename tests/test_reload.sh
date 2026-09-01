#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unset MODE
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
TEST_COMPLETED=false
cleanup() {
    local status=$?
    rm -rf "${TEST_DIR}"
    if [ "${TEST_COMPLETED}" != "true" ] && [ "${status}" -eq 0 ]; then
        echo "测试未执行到完成哨兵，不应报告成功" >&2
        status=1
    fi
    trap - EXIT
    exit "${status}"
}
trap cleanup EXIT
if [ "${TEST_RELOAD_SENTINEL_PROBE:-false}" = "true" ]; then
    exit 0
fi
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
DOWNLOAD_STATUS=0
ORIGINAL_DOWNLOAD_SUBSCRIPTION=$(declare -f download_subscription)
download_subscription() {
    DOWNLOAD_CALLS=$((DOWNLOAD_CALLS + 1))
    if [ "${DOWNLOAD_STATUS}" -ne 0 ]; then
        return "${DOWNLOAD_STATUS}"
    fi
    printf '%s\n' "${DOWNLOAD_CONTENT}" > "${CONFIG_FILE}"
}
ORIGINAL_UPDATE_ALLOW_LAN=$(declare -f update_allow_lan)
ORIGINAL_UPDATE_AUTHENTICATION=$(declare -f update_authentication)
ORIGINAL_ENSURE_CONCURRENCY=$(declare -f ensure_unified_delay_and_tcp_concurrent)
ORIGINAL_INJECT_TUN=$(declare -f inject_tun)
ORIGINAL_INJECT_DNS=$(declare -f inject_dns)
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

if ! update_subscription; then
    echo "成功的订阅更新不应返回失败" >&2
    exit 1
fi
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

(
    eval "${ORIGINAL_UPDATE_ALLOW_LAN}"
    eval "${ORIGINAL_UPDATE_AUTHENTICATION}"
    eval "${ORIGINAL_ENSURE_CONCURRENCY}"
    sed_inplace() { return 1; }
    if update_allow_lan "${CONFIG_FILE}" "true"; then
        echo "allow-lan 写入失败时 helper 不应返回成功" >&2
        exit 1
    fi
    if update_authentication "${CONFIG_FILE}" "user:password"; then
        echo "authentication 写入失败时 helper 不应返回成功" >&2
        exit 1
    fi
    if ensure_unified_delay_and_tcp_concurrent "${CONFIG_FILE}"; then
        echo "并发配置写入失败时 helper 不应返回成功" >&2
        exit 1
    fi
)

(
    eval "${ORIGINAL_INJECT_TUN}"
    eval "${ORIGINAL_INJECT_DNS}"
    cp() { return 1; }
    if inject_tun "${CONFIG_FILE}" "true"; then
        echo "tun 配置复制失败时 helper 不应返回成功" >&2
        exit 1
    fi
    if inject_dns "${CONFIG_FILE}" "true"; then
        echo "DNS 配置复制失败时 helper 不应返回成功" >&2
        exit 1
    fi
)

(
    eval "${ORIGINAL_DOWNLOAD_SUBSCRIPTION}"
    validate_config() { return 0; }
    curl() {
        local output=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then
                output="$2"
                break
            fi
            shift
        done
        printf 'proxies: []\n' > "${output}"
    }
    cp() { return 1; }
    if download_subscription "https://example.com/subscription" "${CONFIG_FILE}" "false"; then
        echo "目标配置写入失败时下载不应返回成功" >&2
        exit 1
    fi
)

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

cp "${CONFIG_FILE}" "${TEST_DIR}/before-download-failure.yaml"
DOWNLOAD_CALLS_BEFORE=${DOWNLOAD_CALLS}
DOWNLOAD_STATUS=1
if update_subscription; then
    echo "订阅下载失败时 update_subscription 不应返回成功" >&2
    exit 1
fi
[ "${DOWNLOAD_CALLS}" -eq $((DOWNLOAD_CALLS_BEFORE + 1)) ]
cmp "${TEST_DIR}/before-download-failure.yaml" "${CONFIG_FILE}"
DOWNLOAD_STATUS=0

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

ORIGINAL_UPDATE_MODE=$(declare -f update_mode)
cat > "${CONFIG_FILE}" <<'EOF'
secret: 'controller-secret'
mixed-port: 7890
routing-mark: 1
proxies: []
EOF
update_mode() { return 1; }
RELOAD_CALLS=0
if update_subscription; then
    echo "代理模式更新失败时 update_subscription 不应返回成功" >&2
    exit 1
fi
[ "${RELOAD_CALLS}" -eq 0 ]
[ "${RESTART_CALLED}" = "false" ]
grep -q "routing-mark: 1" "${CONFIG_FILE}"
! grep -q "routing-mark: 2" "${CONFIG_FILE}"
eval "${ORIGINAL_UPDATE_MODE}"

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

ORIGINAL_PERFORM_SUBSCRIPTION_UPDATE=$(declare -f perform_subscription_update)
PERFORM_STATUS=23
PERFORM_CALLS=0
perform_subscription_update() {
    PERFORM_CALLS=$((PERFORM_CALLS + 1))
    return "${PERFORM_STATUS}"
}
if update_subscription; then
    echo "perform_subscription_update 失败时 update_subscription 不应返回成功" >&2
    exit 1
else
    UPDATE_STATUS=$?
fi
[ "${UPDATE_STATUS}" -eq "${PERFORM_STATUS}" ]
if { : >&9; } 2>/dev/null; then
    echo "订阅更新结束后文件锁描述符应释放" >&2
    exit 1
fi
PERFORM_STATUS=0
update_subscription
[ "${PERFORM_CALLS}" -eq 2 ]
if { : >&9; } 2>/dev/null; then
    echo "订阅更新成功后文件锁描述符应释放" >&2
    exit 1
fi
eval "${ORIGINAL_PERFORM_SUBSCRIPTION_UPDATE}"

if TEST_RELOAD_SENTINEL_PROBE=true bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
    echo "未完成测试哨兵必须让脚本返回非零" >&2
    exit 1
fi

TEST_COMPLETED=true
echo "配置热加载测试通过"
