#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${REPO_DIR}/start.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT

assert_file_contains() {
    local file="$1"
    local expected="$2"
    grep -Fqx -- "${expected}" "${file}"
}

# 小型但完整的配置不应再被任意的 1 KB 阈值拒绝。
SMALL_CONFIG="${TEST_DIR}/small.yaml"
printf '%s\n' 'mixed-port: 7890' 'proxies: []' > "${SMALL_CONFIG}"
validate_config "${SMALL_CONFIG}"

# 纯本地模式未设置覆写项时不得擅自改写用户配置（兼容 :ro 单文件挂载）。
(
    CONFIG_FILE="${TEST_DIR}/local-untouched.yaml"
    SECRET=''
    ALLOW_LAN=''
    AUTHENTICATION=''
    HTTP_PORT=''
    SOCKS_PORT=''
    MIXED_PORT=''
    MODE=''
    TUN_ENABLED=''
    TUN_AUTO_REDIRECT=''
    DNS_OVERRIDE=''
    printf '%s\n' 'mixed-port: 7890' 'proxies: []' > "${CONFIG_FILE}"
    cp "${CONFIG_FILE}" "${TEST_DIR}/local-untouched-before.yaml"
    prepare_existing_config "${CONFIG_FILE}" false
    cmp "${TEST_DIR}/local-untouched-before.yaml" "${CONFIG_FILE}"
)

# 用户输入必须按 YAML 标量转义，逗号分隔的认证项必须真正展开成列表。
CONFIG_FILE="${TEST_DIR}/quoted.yaml"
printf '%s\n' 'mixed-port: 7890' 'secret: old' 'authentication:' '  - old:old' 'proxies: []' > "${CONFIG_FILE}"
update_secret "${CONFIG_FILE}" "pa'ss&word"
assert_file_contains "${CONFIG_FILE}" "secret: 'pa''ss&word'"
update_secret "${CONFIG_FILE}" 'literal\nbackslash'
assert_file_contains "${CONFIG_FILE}" "secret: 'literal\nbackslash'"
update_authentication "${CONFIG_FILE}" 'alice:one,bob:two'
assert_file_contains "${CONFIG_FILE}" "  - 'alice:one'"
assert_file_contains "${CONFIG_FILE}" "  - 'bob:two'"
[ "$(grep -c '^authentication:' "${CONFIG_FILE}")" -eq 1 ]

# 代理端口覆写必须补齐缺失字段、替换重复字段，并在本地配置预处理时生效。
(
    CONFIG_FILE="${TEST_DIR}/ports.yaml"
    SECRET=''
    ALLOW_LAN=''
    AUTHENTICATION=''
    HTTP_PORT=17890
    SOCKS_PORT=17891
    MIXED_PORT=17892
    MODE=''
    TUN_ENABLED=''
    TUN_AUTO_REDIRECT=''
    DNS_OVERRIDE=''
    FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT=false
    printf '%s\n' \
        'port: 7890' \
        'port: 8890' \
        'socks-port: 7891' \
        'proxies: []' > "${CONFIG_FILE}"
    prepare_existing_config "${CONFIG_FILE}" false
    assert_file_contains "${CONFIG_FILE}" 'port: 17890'
    assert_file_contains "${CONFIG_FILE}" 'socks-port: 17891'
    assert_file_contains "${CONFIG_FILE}" 'mixed-port: 17892'
    [ "$(grep -c '^port:' "${CONFIG_FILE}")" -eq 1 ]
)

# 订阅候选配置必须应用同一组端口覆写，避免下次更新恢复机场端口。
(
    CANDIDATE="${TEST_DIR}/subscription-ports.yaml"
    SUB_URL='https://example.invalid/sub'
    SECRET=''
    ALLOW_LAN=''
    AUTHENTICATION=''
    HTTP_PORT=27890
    SOCKS_PORT=27891
    MIXED_PORT=27892
    MODE=''
    TUN_ENABLED=''
    TUN_AUTO_REDIRECT=''
    DNS_OVERRIDE=''
    FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT=false
    HOOK_DIR="${TEST_DIR}/missing-hooks"
    MIHOMO_BIN="${TEST_DIR}/missing-mihomo"
    download_subscription() {
        printf '%s\n' 'mixed-port: 7890' 'proxies: []' > "$2"
    }
    build_subscription_candidate "${CANDIDATE}" direct false
    assert_file_contains "${CANDIDATE}" 'port: 27890'
    assert_file_contains "${CANDIDATE}" 'socks-port: 27891'
    assert_file_contains "${CANDIDATE}" 'mixed-port: 27892'
)

# TUN auto-redirect 可针对不兼容的 NAS 内核显式关闭。
(
    CONFIG_FILE="${TEST_DIR}/tun-auto-redirect.yaml"
    printf '%s\n' 'mixed-port: 7890' 'proxies: []' > "${CONFIG_FILE}"
    inject_tun "${CONFIG_FILE}" true false
    assert_file_contains "${CONFIG_FILE}" '  auto-redirect: false'
)

# 本地配置路径也必须执行 DNS_OVERRIDE，且只保留一个 dns 顶级块。
(
    CONFIG_FILE="${TEST_DIR}/local-dns.yaml"
    HOOK_DIR="${TEST_DIR}/missing-hooks"
    SECRET=''
    ALLOW_LAN=''
    AUTHENTICATION=''
    HTTP_PORT=''
    SOCKS_PORT=''
    MIXED_PORT=''
    MODE=''
    TUN_ENABLED=''
    TUN_AUTO_REDIRECT=''
    DNS_OVERRIDE=true
    FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT=false
    printf '%s\n' \
        'mixed-port: 7890' \
        'dns:' \
        '  enable: false' \
        'proxies: []' \
        'dns:' \
        '  enable: false' > "${CONFIG_FILE}"
    prepare_existing_config "${CONFIG_FILE}"
    [ "$(grep -c '^dns:' "${CONFIG_FILE}")" -eq 1 ]
    assert_file_contains "${CONFIG_FILE}" '  enable: true'
    assert_file_contains "${CONFIG_FILE}" '    geosite:gfw: "tls://1.1.1.1"'
    ! grep -q '^[[:space:]]*geosite:$' "${CONFIG_FILE}"
    ! grep -q 'internal.crop.com' "${CONFIG_FILE}"
)

# Hook 名称包含空格时仍应执行；失败必须向上传播。
(
    HOOK_DIR="${TEST_DIR}/hooks"
    mkdir -p "${HOOK_DIR}"
    printf '%s\n' '#!/bin/bash' 'printf executed > "$(dirname "$1")/hook-ran"' > "${HOOK_DIR}/10 hook with spaces.sh"
    chmod +x "${HOOK_DIR}/10 hook with spaces.sh"
    run_post_subscription_hooks "${SMALL_CONFIG}"
    assert_file_contains "${TEST_DIR}/hook-ran" executed

    printf '%s\n' '#!/bin/bash' 'exit 23' > "${HOOK_DIR}/20-fail.sh"
    chmod +x "${HOOK_DIR}/20-fail.sh"
    if run_post_subscription_hooks "${SMALL_CONFIG}"; then
        echo '失败的 Hook 不应返回成功' >&2
        exit 1
    fi
)

# 候选订阅在 Hook/变换失败时不得覆盖正在使用的配置。
(
    CONFIG_FILE="${TEST_DIR}/transaction.yaml"
    HOOK_DIR="${TEST_DIR}/transaction-hooks"
    SUB_URL='https://example.invalid/sub'
    SECRET=''
    ALLOW_LAN=''
    AUTHENTICATION=''
    HTTP_PORT=''
    SOCKS_PORT=''
    MIXED_PORT=''
    MODE=''
    TUN_ENABLED=''
    TUN_AUTO_REDIRECT=''
    DNS_OVERRIDE=''
    FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT=false
    mkdir -p "${HOOK_DIR}"
    printf '%s\n' '#!/bin/bash' 'exit 1' > "${HOOK_DIR}/fail.sh"
    chmod +x "${HOOK_DIR}/fail.sh"
    printf '%s\n' 'mixed-port: 7890' 'routing-mark: 1' 'proxies: []' > "${CONFIG_FILE}"
    cp "${CONFIG_FILE}" "${TEST_DIR}/transaction-before.yaml"
    download_subscription() {
        printf '%s\n' 'mixed-port: 7890' 'routing-mark: 2' 'proxies: []' > "$2"
    }
    if install_subscription_config direct false; then
        echo '候选配置失败时不应安装订阅' >&2
        exit 1
    fi
    cmp "${TEST_DIR}/transaction-before.yaml" "${CONFIG_FILE}"
)

# 新订阅通过预处理但 Mihomo 启动失败时，必须回退并启动原配置。
(
    CONFIG_FILE="${TEST_DIR}/startup-rollback.yaml"
    printf '%s\n' 'mixed-port: 7890' 'routing-mark: 1' 'proxies: []' > "${CONFIG_FILE}"
    install_subscription_config() {
        printf '%s\n' 'mixed-port: 7890' 'routing-mark: 2' 'proxies: []' > "${CONFIG_FILE}"
    }
    start_mihomo() { return 1; }
    FALLBACK_STARTED=false
    start_from_existing_config() {
        grep -q '^routing-mark: 1$' "${CONFIG_FILE}"
        FALLBACK_STARTED=true
    }
    start_subscription_mode_with_existing_config
    [ "${FALLBACK_STARTED}" = true ]
    grep -q '^routing-mark: 1$' "${CONFIG_FILE}"
)

# 本地配置本身损坏时，仍应保留 DOWNLOAD_PROXY 最后的恢复路径。
(
    CONFIG_FILE="${TEST_DIR}/external-fallback.yaml"
    DOWNLOAD_PROXY='http://proxy.invalid:8080'
    printf '%s\n' 'mixed-port: 7890' 'proxies: []' > "${CONFIG_FILE}"
    install_subscription_config() {
        [ "$1" = external ]
    }
    start_from_existing_config() { return 1; }
    EXTERNAL_STARTED=false
    start_mihomo() { EXTERNAL_STARTED=true; }
    start_subscription_mode_with_existing_config
    [ "${EXTERNAL_STARTED}" = true ]
)

# DOWNLOAD_PROXY 必须作为单个 curl 参数传递，不能发生单词拆分或选项注入。
(
    DOWNLOAD_PROXY='http://proxy.invalid:8080 --next'
    SUB_USER_AGENT='test-agent'
    CURL_ARGS=()
    curl() {
        local output=''
        CURL_ARGS=("$@")
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '-o' ]; then
                output="$2"
                break
            fi
            shift
        done
        printf '%s\n' 'mixed-port: 7890' 'proxies: []' > "${output}"
    }
    download_subscription 'https://example.invalid/sub' "${TEST_DIR}/downloaded.yaml" external
    found=false
    for ((index = 0; index < ${#CURL_ARGS[@]}; index++)); do
        if [ "${CURL_ARGS[$index]}" = '--proxy' ]; then
            [ "${CURL_ARGS[$((index + 1))]}" = "${DOWNLOAD_PROXY}" ]
            found=true
        fi
    done
    [ "${found}" = true ]
    if download_subscription '--config=/tmp/evil' "${TEST_DIR}/invalid-url.yaml" direct; then
        echo '非 HTTP(S) 订阅地址不应传给 curl' >&2
        exit 1
    fi
)

# 本地代理下载端口应读取当前配置，不能硬编码为 7890。
(
    CONFIG_FILE="${TEST_DIR}/custom-port.yaml"
    printf '%s\n' '"mixed-port" : "17892" # custom' 'proxies: []' > "${CONFIG_FILE}"
    [ "$(local_http_proxy_url)" = 'http://127.0.0.1:17892' ]
)

# 重启失败必须保留失败状态，不能被成功日志覆盖。
(
    PID_FILE="${TEST_DIR}/missing.pid"
    start_mihomo() { return 17; }
    if restart_mihomo; then
        echo 'start_mihomo 失败时 restart_mihomo 不应返回成功' >&2
        exit 1
    fi
)

# 环境和 cron 输入在写入系统文件前必须校验。
(
    ALLOW_LAN=maybe
    if load_environment; then
        echo '非法布尔环境变量不应通过校验' >&2
        exit 1
    fi
)
(
    HTTP_PORT=65536
    if load_environment; then
        echo '超出范围的代理端口不应通过校验' >&2
        exit 1
    fi
)
(
    TUN_AUTO_REDIRECT=maybe
    if load_environment; then
        echo '非法的 TUN_AUTO_REDIRECT 不应通过校验' >&2
        exit 1
    fi
)
if validate_cron_schedule '0 * * * *;touch'; then
    echo '含命令注入字符的 cron 表达式不应通过校验' >&2
    exit 1
fi

# 设置 SUB_URL 后，即使没有定时任务也必须生成可手动执行的更新脚本。
(
    UPDATE_SCRIPT="${TEST_DIR}/update_sub.sh"
    SUB_URL='https://example.invalid/sub'
    SUB_CRON=''
    setup_cron "${SUB_CRON}"
    [ -x "${UPDATE_SCRIPT}" ]
    assert_file_contains "${UPDATE_SCRIPT}" 'source /app/start.sh'
    assert_file_contains "${UPDATE_SCRIPT}" 'update_subscription'
    grep -q '^export HTTP_PORT=' "${UPDATE_SCRIPT}"
    grep -q '^export TUN_AUTO_REDIRECT=' "${UPDATE_SCRIPT}"
    grep -q '^export SAFE_PATHS=' "${UPDATE_SCRIPT}"
)

(
    UPDATE_LOCK_FILE="${TEST_DIR}/missing/update.lock"
    perform_subscription_update() { return 0; }
    if update_subscription 2>/dev/null; then
        echo '无法创建更新锁时不应继续执行' >&2
        exit 1
    fi
)

echo '模块回归测试通过'
