#!/bin/bash

CONFIG_DIR="/root/.config/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
HOOK_DIR="/app/hooks.d"
UI_DIR="/app/ui"
GEODATA_DIR="/app/geodata"
CRON_FILE="/etc/crontabs/root"
PID_FILE="/var/run/mihomo.pid"
UPDATE_LOCK_FILE="/var/run/glash-subscription-update.lock"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# 可选环境变量在严格模式或被 source 引入时统一使用空值默认值
: "${SUB_URL:=}"
: "${SECRET:=}"
: "${SUB_CRON:=}"
: "${DOWNLOAD_PROXY:=}"
: "${ALLOW_LAN:=}"
: "${MODE:=}"
: "${TUN_ENABLED:=}"
: "${DNS_OVERRIDE:=}"
: "${SUB_USER_AGENT:=}"
: "${AUTHENTICATION:=}"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${RESET} ${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${RESET} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${RESET} ${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${RESET} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} ${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${RESET} $1"
}

# 验证配置文件完整性
# 返回: 0=有效, 1=无效
validate_config() {
    local file="$1"
    local min_size=1024  # 最小 1KB
    
    # 检查文件是否存在且非空
    if [ ! -s "${file}" ]; then
        log_error "❌ 配置文件为空或不存在"
        return 1
    fi
    
    # 检查文件大小（至少 1KB）
    local file_size=$(wc -c < "${file}")
    if [ "${file_size}" -lt "${min_size}" ]; then
        log_error "❌ 配置文件太小 (${file_size} bytes)，可能不完整"
        return 1
    fi
    
    # 检查必要的关键字段
    local has_port=false
    local has_proxy_definitions=false
    
    if grep -qE "^port:" "${file}" || grep -qE "^mixed-port:" "${file}"; then
        has_port=true
    fi
    
    if grep -qE "^(proxies|proxy-providers):" "${file}"; then
        has_proxy_definitions=true
    fi
    
    if [ "${has_port}" = "false" ]; then
        log_error "❌ 配置文件缺少 port 或 mixed-port 字段"
        return 1
    fi
    
    if [ "${has_proxy_definitions}" = "false" ]; then
        log_error "配置文件缺少 proxies 或 proxy-providers 字段"
        return 1
    fi
    
    # 检查文件末尾是否正常（不是被截断的）
    # 获取最后 10 行，检查是否有内容
    local last_lines=$(tail -10 "${file}" | grep -v "^$" | wc -l)
    if [ "${last_lines}" -lt 1 ]; then
        log_error "❌ 配置文件末尾异常，可能被截断"
        return 1
    fi
    
    log_info "✅ 配置文件验证通过 (${file_size} bytes)"
    return 0
}

# 下载订阅配置
# 参数: url, output, [use_proxy: true/false]
download_subscription() {
    local url="$1"
    local output="$2"
    local use_proxy="${3:-false}"
    local temp_file="/tmp/subscription_config.yaml"
    local max_retries=3
    local retry_delay=5
    local proxy_args=""
    
    # 设置代理参数
    if [ "${use_proxy}" = "true" ]; then
        if [ -n "${DOWNLOAD_PROXY}" ]; then
            proxy_args="--proxy ${DOWNLOAD_PROXY}"
            log_info "🔗 使用外部代理下载: ${DOWNLOAD_PROXY}"
        else
            proxy_args="--proxy http://127.0.0.1:7890"
            log_info "🔗 使用本地代理下载: http://127.0.0.1:7890"
        fi
    else
        log_info "🔗 直连模式下载..."
    fi
    
    log_info "🔗 正在从订阅地址下载配置..."
    
    # 重试机制
    for ((i=1; i<=max_retries; i++)); do
        log_info "🔗 下载尝试 $i/$max_retries ..."
        
        # 清理旧的临时文件
        rm -f "${temp_file}"
        
        # 下载到临时文件（使用 /tmp 避免文件被占用）
        if curl -fsSL ${proxy_args} -A "${SUB_USER_AGENT:-clash.meta}" --connect-timeout 60 --max-time 300 --retry 2 --retry-delay 3 -o "${temp_file}" "${url}"; then
            # 验证下载的文件完整性
            if validate_config "${temp_file}"; then
                # 使用 cp 而不是 mv，避免跨文件系统问题和文件占用问题
                if cp -f "${temp_file}" "${output}"; then
                    rm -f "${temp_file}"
                    log_info "✅ 订阅配置下载成功"
                    return 0
                fi
                log_warn "❌ 配置文件写入失败，${retry_delay} 秒后重试..."
                rm -f "${temp_file}"
                sleep "${retry_delay}"
            else
                log_error "❌ 下载的配置文件验证失败"
                rm -f "${temp_file}"
            fi
        else
            log_warn "❌ 下载失败，$retry_delay 秒后重试..."
            rm -f "${temp_file}"
            sleep "${retry_delay}"
        fi
    done
    
    log_error "❌ 订阅配置下载失败（已重试 $max_retries 次）"
    return 1
}

# 原地替换文件内容（使用临时文件 + cp，保留 inode，避免 "resource busy" 错误）
sed_inplace() {
    local expr="$1"
    local file="$2"
    local temp_file
    if ! temp_file=$(mktemp); then
        log_error "❌ 无法创建临时文件"
        return 1
    fi
    if ! sed "${expr}" "${file}" > "${temp_file}" || ! cp -f "${temp_file}" "${file}"; then
        log_error "❌ 配置文件写入失败"
        rm -f "${temp_file}"
        return 1
    fi
    rm -f "${temp_file}"
}

# 更新配置文件中的 secret
update_secret() {
    local config="$1"
    local secret="$2"
    local expr
    
    log_info "🔗 正在更新配置文件中的 secret..."

    if grep -Fqx -- "secret: '${secret}'" "${config}"; then
        log_info "✅ secret 已更新"
        return 0
    fi
    
    # 检查配置文件中是否已有 secret 字段
    if grep -qE "^secret:" "${config}"; then
        # 替换现有的 secret
        expr="s/^secret:.*$/secret: '${secret}'/"
    else
        # 在 external-controller 后面添加 secret
        if grep -qE "^external-controller:" "${config}"; then
            expr="/^external-controller:/a secret: '${secret}'"
        else
            # 如果没有 external-controller，直接在文件开头添加
            expr="1i secret: '${secret}'"
        fi
    fi

    sed_inplace "${expr}" "${config}" || return 1
    
    log_info "✅ secret 已更新"
}

# 更新配置文件中的 authentication
# 参数: config, authentication (格式: "username:password")
update_authentication() {
    local config="$1"
    local auth="$2"

    if [ -z "${auth}" ]; then
        return 0
    fi

    log_info "🔗 正在更新配置文件中的 authentication..."

    # 检查配置文件中是否已有 authentication 字段，如有则删除整个块
    if grep -qE "^authentication:" "${config}"; then
        local temp_file
        if ! temp_file=$(mktemp); then
            log_error "❌ 无法创建临时文件"
            return 1
        fi
        if ! awk '/^authentication:/{skip=1; next} skip && /^[a-zA-Z]/{skip=0} !skip{print}' "${config}" > "${temp_file}" || \
            ! cp -f "${temp_file}" "${config}"; then
            log_error "❌ authentication 配置写入失败"
            rm -f "${temp_file}"
            return 1
        fi
        rm -f "${temp_file}"
    fi

    # 添加 authentication 配置
    if grep -qE "^secret:" "${config}"; then
        sed_inplace "/^secret:/a authentication:\n  - '${auth}'" "${config}" || return 1
    elif grep -qE "^external-controller:" "${config}"; then
        sed_inplace "/^external-controller:/a authentication:\n  - '${auth}'" "${config}" || return 1
    else
        sed_inplace "1i authentication:\n  - '${auth}'" "${config}" || return 1
    fi

    log_info "✅ authentication 已更新"
}

# 确保配置文件中包含 unified-delay 和 tcp-concurrent 设置
force_boolean_key_true_preserve_comment() {
    local config="$1"
    local key="$2"
    local escaped_key

    escaped_key=$(printf '%s\n' "${key}" | sed 's/[][\/.^$*]/\\&/g')
    sed_inplace "/^[[:space:]]*${escaped_key}:[[:space:]]*/{
s/^\([[:space:]]*${escaped_key}:[[:space:]]*\)[^#]*\([[:space:]]*#.*\)\{0,1\}$/\1true\2/
}" "${config}"
}

ensure_unified_delay_and_tcp_concurrent() {
    local config="$1"
    local force_override="${FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT:-false}"
    
    log_info "🔗 正在确保配置文件中包含 unified-delay 和 tcp-concurrent 设置..."
    
    # 处理 unified-delay
    if grep -qE "^[[:space:]]*unified-delay:" "${config}"; then
        if [ "${force_override}" = "true" ]; then
            force_boolean_key_true_preserve_comment "${config}" "unified-delay" || return 1
        fi
    else
        # 尝试在 secret 后面添加（如果存在 secret）
        if grep -qE "^[[:space:]]*secret:" "${config}"; then
            sed_inplace "/^[[:space:]]*secret:/a unified-delay: true" "${config}" || return 1
        elif grep -qE "^[[:space:]]*external-controller:" "${config}"; then
            sed_inplace "/^[[:space:]]*external-controller:/a unified-delay: true" "${config}" || return 1
        else
            sed_inplace "1i unified-delay: true" "${config}" || return 1
        fi
    fi
    
    # 处理 tcp-concurrent
    if grep -qE "^[[:space:]]*tcp-concurrent:" "${config}"; then
        if [ "${force_override}" = "true" ]; then
            force_boolean_key_true_preserve_comment "${config}" "tcp-concurrent" || return 1
        fi
    else
        # 尝试在 unified-delay 后面添加
        if grep -qE "^[[:space:]]*unified-delay:" "${config}"; then
            sed_inplace "/^[[:space:]]*unified-delay:/a tcp-concurrent: true" "${config}" || return 1
        elif grep -qE "^[[:space:]]*secret:" "${config}"; then
            sed_inplace "/^[[:space:]]*secret:/a tcp-concurrent: true" "${config}" || return 1
        elif grep -qE "^[[:space:]]*external-controller:" "${config}"; then
            sed_inplace "/^[[:space:]]*external-controller:/a tcp-concurrent: true" "${config}" || return 1
        else
            sed_inplace "1i tcp-concurrent: true" "${config}" || return 1
        fi
    fi
    
    if [ "${force_override}" = "true" ]; then
        log_info "✅ unified-delay 和 tcp-concurrent 已检查；缺失项已补齐，存在项已强制设为 true"
    else
        log_info "✅ unified-delay 和 tcp-concurrent 已检查；仅为缺失项补齐默认值，不覆盖已有配置"
    fi
}

# 注入 TUN 模式配置
# 参数: config, tun_enabled (true/false)
# 若 tun_enabled 为空则不做任何修改
inject_tun() {
    local config="$1"
    local tun_enabled="$2"

    if [ -z "${tun_enabled}" ]; then
        return 0
    fi

    log_info "🔗 正在更新配置文件中的 tun 配置..."

    # 移除现有的 tun 配置块（从 ^tun: 到下一个顶级 key 之前）
    local temp_file
    if ! temp_file=$(mktemp); then
        log_error "❌ 无法创建临时文件"
        return 1
    fi
    if ! awk '/^tun:/{skip=1; next} skip && /^[a-zA-Z]/{skip=0} !skip{print}' "${config}" > "${temp_file}" || \
        ! cp -f "${temp_file}" "${config}"; then
        log_error "❌ tun 配置写入失败"
        rm -f "${temp_file}"
        return 1
    fi
    rm -f "${temp_file}"

    if [ "${tun_enabled}" = "true" ]; then
        if ! cat >> "${config}" << 'EOF'
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
EOF
        then
            log_error "❌ tun 配置写入失败"
            return 1
        fi
        log_info "✅ tun 模式已启用"
    else
        if ! cat >> "${config}" << 'EOF'
tun:
  enable: false
EOF
        then
            log_error "❌ tun 配置写入失败"
            return 1
        fi
        log_info "✅ tun 模式已显式关闭"
    fi
    }

    # 注入 DNS 覆写配置
    inject_dns() {
    local config="$1"
    local dns_override="$2"

    [ "$dns_override" != "true" ] && return 0

    log_info "🔗 正在覆写配置文件中的 DNS 配置..."

    # 移除现有的 dns 配置块
    local temp_file
    if ! temp_file=$(mktemp); then
        log_error "❌ 无法创建临时文件"
        return 1
    fi
    if ! awk '/^dns:/{skip=1; next} skip && /^[a-zA-Z]/{skip=0} !skip{print}' "${config}" > "${temp_file}" || \
        ! cp -f "${temp_file}" "${config}"; then
        log_error "❌ DNS 配置写入失败"
        rm -f "${temp_file}"
        return 1
    fi
    rm -f "${temp_file}"

# 精简版
# dns:
#   enable: true
#   listen: 0.0.0.0:1053
#   default-nameserver:
#     - 223.5.5.5
#     - 1.1.1.1
#   enhanced-mode: fake-ip
#   fake-ip-range: 198.18.0.1/16
#   fake-ip-filter:
#     - "*.lan"
#     - "*.localhost"
#   nameserver:
#     - https://dns.alidns.com/dns-query
#     - https://doh.pub/dns-query

    if ! cat >> "${config}" << 'EOF'
dns:
  enable: true
  listen: "0.0.0.0:1053"
  prefer-h3: true
  use-hosts: true
  use-system-hosts: true
  respect-rules: false
  ipv6: true
  default-nameserver:
    - "223.5.5.5"
  enhanced-mode: "fake-ip"
  fake-ip-range: "198.18.0.1/16"
  fake-ip-filter:
    - "*.lan"
    - "localhost.ptlogin2.qq.com"
  nameserver-policy:
    www.baidu.com: "114.114.114.114"
    +.internal.crop.com: "10.0.0.1"
    geosite:cn: "https://doh.pub/dns-query"
  nameserver:
    - "https://doh.pub/dns-query"
    - "https://dns.alidns.com/dns-query"
    - "system://"
  fallback:
    - "tls://8.8.4.4"
    - "tls://1.1.1.1"
  proxy-server-nameserver:
    - "https://doh.pub/dns-query"
  fallback-filter:
    geoip: true
    geoip-code: "CN"
    geosite:
      - "gfw"
    ipcidr:
      - "240.0.0.0/4"
    domain:
      - "+.google.com"
      - "+.facebook.com"
      - "+.youtube.com"
EOF
    then
        log_error "❌ DNS 配置写入失败"
        return 1
    fi
    log_info "✅ DNS 配置已覆写"
    }


# 更新配置文件中的 allow-lan
update_allow_lan() {
    local config="$1"
    local allow_lan="$2"

    if [ -z "${allow_lan}" ]; then
        return 0
    fi

    log_info "🔗 正在更新配置文件中的 allow-lan..."

    # 检查配置文件中是否已有 allow-lan 字段
    if grep -qE "^allow-lan:" "${config}"; then
        # 替换现有的 allow-lan
        sed_inplace "s/^allow-lan:.*$/allow-lan: ${allow_lan}/" "${config}" || return 1
    else
        # 在文件开头添加
        sed_inplace "1i allow-lan: ${allow_lan}" "${config}" || return 1
    fi

    log_info "✅ allow-lan 已更新为 ${allow_lan}"
}

# 更新配置文件中的代理模式
update_mode() {
    local config="$1"
    local mode="$2"

    if [ -z "${mode}" ]; then
        return 0
    fi

    case "${mode}" in
        rule|global|direct)
            ;;
        *)
            log_warn "❌ MODE 仅支持 rule、global 或 direct，保持配置文件中的代理模式不变"
            return 0
            ;;
    esac

    log_info "🔗 正在更新配置文件中的代理模式..."
    local temp_file
    if ! temp_file=$(mktemp "${config}.mode.XXXXXX"); then
        log_error "❌ 无法创建临时文件"
        return 1
    fi
    if ! cp -p "${config}" "${temp_file}" || ! awk -v mode="${mode}" '
        function is_mode(line) {
            return line ~ /^mode[[:space:]]*:/ || line ~ /^"mode"[[:space:]]*:/ || line ~ /^\047mode\047[[:space:]]*:/
        }
        NR == 1 && substr($0, 1, 3) == "\357\273\277" {
            printf "%s", substr($0, 1, 3)
            $0 = substr($0, 4)
        }
        !inserted && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^#/ || $0 ~ /^%/ || $0 ~ /^---([[:space:]]|$)/) {
            print
            next
        }
        !inserted {
            print "mode: " mode
            inserted = 1
        }
        !is_mode($0) {
            print
        }
        END {
            if (!inserted) {
                print "mode: " mode
            }
        }
    ' "${config}" > "${temp_file}" || ! mv -f "${temp_file}" "${config}"; then
        rm -f "${temp_file}"
        log_error "❌ 代理模式更新失败，请挂载可写配置目录而非单个 config.yaml"
        return 1
    fi
    rm -f "${temp_file}"
    log_info "✅ 代理模式已更新为 ${mode}"
}



# ==================== Hook 功能 ====================

# 执行订阅更新后的 hook 脚本
# 参数: config_file - 配置文件路径
# 返回: 0=成功, 1=失败
run_post_subscription_hooks() {
    local config_file="$1"
    
    
    # 执行目录中的所有可执行脚本（按字母顺序）
    if [ -d "${HOOK_DIR}" ]; then
        log_info "🔧 扫描 hook 目录: ${HOOK_DIR}"
        local hook_count=0
        
        for script in $(find "${HOOK_DIR}" -maxdepth 1 -type f -executable | sort); do
            hook_count=$((hook_count + 1))
            log_info "🔧 执行 hook: $(basename "${script}")"
            if bash "${script}" "${config_file}"; then
                log_info "✅ Hook $(basename "${script}") 执行成功"
            else
                log_error "❌ Hook $(basename "${script}") 执行失败，停止启动流程"
                return 1
            fi
        done
        
        if [ ${hook_count} -eq 0 ]; then
            log_info "📁 Hook 目录 ${HOOK_DIR} 中没有可执行脚本"
        else
            log_info "✅ 共执行 ${hook_count} 个 hook"
        fi
    fi

    return 0
}



# 确保 external-controller 配置正确（默认值: 0.0.0.0:9090）
ensure_external_controller() {
    local config="$1"
    local default_value="0.0.0.0:9090"
    local default_pattern="0\.0\.0\.0:9090"

    if grep -qE "^external-controller:" "${config}"; then
        # 已存在，检查值是否为默认值，不是则修正
        if ! grep -qE "^external-controller: ${default_pattern}$" "${config}"; then
            log_info "🔗 修正 external-controller 配置为默认值..."
            if ! sed_inplace "s/^external-controller:.*$/external-controller: ${default_value}/" "${config}"; then
                return 1
            fi
        fi
    else
        log_info "🔗 添加 external-controller 配置..."
        if ! sed_inplace "1i external-controller: ${default_value}" "${config}"; then
            return 1
        fi
    fi
}

# 启动 mihomo
# 返回: 0=成功, 1=失败
start_mihomo() {
    log_info "🚀 正在启动 mihomo..."
    /app/mihomo -d "${CONFIG_DIR}" -ext-ui "${UI_DIR}" &
    local pid=$!
    echo "${pid}" > "${PID_FILE}"
    
    # 等待一小段时间检查进程是否存活
    sleep 2
    
    if kill -0 "${pid}" 2>/dev/null; then
        log_info "🎉 mihomo 已启动，PID: ${pid}"
        return 0
    else
        log_error "❌ mihomo 启动失败（可能是配置文件错误）"
        return 1
    fi
}

# 重启 mihomo
restart_mihomo() {
    log_info "🔄 正在重启 mihomo..."
    
    if [ -f "${PID_FILE}" ]; then
        local old_pid=$(cat "${PID_FILE}")
        if kill -0 "${old_pid}" 2>/dev/null; then
            kill "${old_pid}"
            # 等待进程退出
            local count=0
            while kill -0 "${old_pid}" 2>/dev/null && [ $count -lt 10 ]; do
                sleep 1
                count=$((count + 1))
            done
            if kill -0 "${old_pid}" 2>/dev/null; then
                log_warn "❌ mihomo 未正常退出，强制终止..."
                kill -9 "${old_pid}" 2>/dev/null
            fi
        fi
    fi
    
    start_mihomo
    log_info "🎉 mihomo 重启完成"
}

# 恢复热加载前的配置
restore_config_backup() {
    local backup_file="$1"

    if cp -f "${backup_file}" "${CONFIG_FILE}"; then
        rm -f "${backup_file}"
        log_warn "⚠️ 已恢复热加载前的配置文件"
        return 0
    fi

    log_error "❌ 配置文件恢复失败，备份保留在 ${backup_file}"
    return 1
}

# 验证当前 External Controller 可访问且密钥正确
check_mihomo_controller() {
    local controller_secret="${1:-}"
    local request_args=(-fsS --noproxy '*' --connect-timeout 5 --max-time 10)

    if [ -n "${controller_secret}" ]; then
        request_args+=(-H "Authorization: Bearer ${controller_secret}")
    fi

    curl "${request_args[@]}" "http://127.0.0.1:9090/version" >/dev/null
}

# 通过 External Controller 热加载配置，避免终止容器主进程等待的 mihomo
reload_mihomo_config() {
    local controller_url="http://127.0.0.1:9090/configs?force=true"
    local controller_secret="${1:-${SECRET:-}}"
    local request_args=(
        -fsS
        --noproxy '*'
        --connect-timeout 5
        --max-time 30
        -X PUT
        -H "Content-Type: application/json"
        -d '{"path":"","payload":""}'
    )

    if [ -n "${controller_secret}" ]; then
        request_args+=(-H "Authorization: Bearer ${controller_secret}")
    fi

    local attempt
    for attempt in 1 2; do
        log_info "🔄 正在热加载 mihomo 配置（${attempt}/2）..."
        if curl "${request_args[@]}" "${controller_url}"; then
            log_info "🎉 mihomo 配置热加载完成"
            return 0
        fi
        [ "${attempt}" -lt 2 ] && sleep 1
    done

    log_error "❌ mihomo 配置热加载失败，保持当前进程运行"
    return 1
}

# 恢复旧配置，并让仍在运行的 mihomo 回到旧配置
restore_and_reload_config() {
    local backup_file="$1"
    local controller_secret="$2"

    restore_config_backup "${backup_file}" || return 1
    if ! reload_mihomo_config "${controller_secret}"; then
        log_error "❌ 旧配置补偿加载失败，运行态可能与磁盘配置不一致"
        return 1
    fi
}

# 执行订阅更新（由带锁的 update_subscription 调用）
perform_subscription_update() {
    if [ -z "${SUB_URL}" ]; then
        log_warn "❌ 未设置 SUB_URL，跳过订阅更新"
        return 1
    fi

    local controller_secret="${SECRET:-}"
    if ! check_mihomo_controller "${controller_secret}"; then
        log_error "❌ 无法访问 Mihomo Controller；若配置启用了 secret，请设置匹配的 SECRET 环境变量"
        return 1
    fi

    local config_backup
    if ! config_backup=$(mktemp "${CONFIG_FILE}.backup.XXXXXX") || ! cp -p "${CONFIG_FILE}" "${config_backup}"; then
        [ -n "${config_backup:-}" ] && rm -f "${config_backup}"
        log_error "❌ 无法备份当前配置，取消订阅更新"
        return 1
    fi
    
    log_info "🔗 开始更新订阅..."
    
    # 定时更新时使用本地代理
    if ! download_subscription "${SUB_URL}" "${CONFIG_FILE}" "true"; then
        restore_config_backup "${config_backup}" || true
        log_error "❌ 订阅更新失败，保持当前配置"
        return 1
    fi

    # 所有配置变更都在同一份备份保护下进行，任一步失败都恢复旧配置。
    if ! update_secret "${CONFIG_FILE}" "${controller_secret}"; then
        restore_config_backup "${config_backup}" || true
        return 1
    fi

    if [ -n "${ALLOW_LAN}" ] && ! update_allow_lan "${CONFIG_FILE}" "${ALLOW_LAN}"; then
        restore_config_backup "${config_backup}" || true
        return 1
    fi

    if [ -n "${AUTHENTICATION}" ] && ! update_authentication "${CONFIG_FILE}" "${AUTHENTICATION}"; then
        restore_config_backup "${config_backup}" || true
        return 1
    fi

    if ! ensure_unified_delay_and_tcp_concurrent "${CONFIG_FILE}" || \
        ! inject_tun "${CONFIG_FILE}" "${TUN_ENABLED}" || \
        ! inject_dns "${CONFIG_FILE}" "${DNS_OVERRIDE}" || \
        ! ensure_external_controller "${CONFIG_FILE}"; then
        restore_config_backup "${config_backup}" || true
        return 1
    fi

    # ========== 新增：执行外部 Hook ==========
    if ! run_post_subscription_hooks "${CONFIG_FILE}"; then
        log_error "❌ 执行外部Hook失败"
        restore_config_backup "${config_backup}" || true
        return 1
    fi
    # ========================================

    if ! update_mode "${CONFIG_FILE}" "${MODE}"; then
        restore_config_backup "${config_backup}" || true
        return 1
    fi

    # 保持热加载通道在更新前后使用相同的地址和密钥。
    if ! update_secret "${CONFIG_FILE}" "${controller_secret}" || \
        ! ensure_external_controller "${CONFIG_FILE}"; then
        restore_config_backup "${config_backup}" || true
        return 1
    fi

    # 热加载配置，避免终止主进程导致容器重启。
    if ! reload_mihomo_config "${controller_secret}"; then
        restore_and_reload_config "${config_backup}" "${controller_secret}" || true
        return 1
    fi

    rm -f "${config_backup}"
    log_info "🎉 订阅更新完成"
    return 0
}

# 更新订阅（用于定时任务，通过本地代理下载）
update_subscription() {
    exec 9>"${UPDATE_LOCK_FILE}"
    if ! flock -n 9; then
        log_warn "⚠️ 已有订阅更新正在执行，跳过本次任务"
        exec 9>&-
        return 1
    fi

    local status
    if perform_subscription_update; then
        status=0
    else
        status=$?
    fi
    exec 9>&-
    return "${status}"
}

# 设置定时任务
setup_cron() {
    local cron_schedule="$1"
    
    if [ -z "${cron_schedule}" ]; then
        log_info "🔔 未设置 SUB_CRON，跳过定时任务配置"
        return 0
    fi
    
    log_info "🔗 设置订阅更新定时任务: ${cron_schedule}"
    
    # 创建更新脚本
    cat > /app/update_sub.sh << 'SCRIPT'
#!/bin/bash
source /app/start.sh
update_subscription
SCRIPT
    chmod +x /app/update_sub.sh
    
    # 设置环境变量到 cron 任务
    cat > "${CRON_FILE}" << EOF
# 订阅更新定时任务
SUB_URL=${SUB_URL}
SECRET=${SECRET}
ALLOW_LAN=${ALLOW_LAN}
MODE=${MODE}
TUN_ENABLED=${TUN_ENABLED}
DNS_OVERRIDE=${DNS_OVERRIDE}
SUB_USER_AGENT=${SUB_USER_AGENT}
AUTHENTICATION=${AUTHENTICATION}
${cron_schedule} /app/update_sub.sh >> /var/log/subscription.log 2>&1
EOF
    
    # 启动 crond
    crond -b -l 8
    log_info "🎉 定时任务已启动"
}

# 信号处理
handle_signal() {
    log_info "🔔 收到终止信号，正在关闭..."
    if [ -f "${PID_FILE}" ]; then
        local pid=$(cat "${PID_FILE}")
        kill "${pid}" 2>/dev/null
    fi
    exit 0
}

trap handle_signal SIGTERM SIGINT

# ==================== 主逻辑 ====================

# 如果是被 source 引入的，只提供函数，不执行主逻辑
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

log_info "🚀 glash 启动中 🚀"

# 清理环境变量中的引号（用户可能在 docker-compose 中错误添加了引号）
SUB_URL=$(echo "${SUB_URL}" | sed "s/^['\"]//;s/['\"]$//")
SECRET=$(echo "${SECRET}" | sed "s/^['\"]//;s/['\"]$//")
SUB_CRON=$(echo "${SUB_CRON}" | sed "s/^['\"]//;s/['\"]$//")
DOWNLOAD_PROXY=$(echo "${DOWNLOAD_PROXY}" | sed "s/^['\"]//;s/['\"]$//")
ALLOW_LAN=$(echo "${ALLOW_LAN}" | sed "s/^['\"]//;s/['\"]$//")
MODE=$(echo "${MODE}" | sed "s/^['\"]//;s/['\"]$//")
case "${MODE}" in
    ""|rule|global|direct)
        ;;
    *)
        log_warn "❌ MODE 仅支持 rule、global 或 direct，将忽略当前值"
        MODE=""
        ;;
esac
TUN_ENABLED=$(echo "${TUN_ENABLED}" | sed "s/^['\"]//;s/['\"]$//")
DNS_OVERRIDE=$(echo "${DNS_OVERRIDE}" | sed "s/^['\"]//;s/['\"]$//")
SUB_USER_AGENT=$(echo "${SUB_USER_AGENT}" | sed "s/^['\"]//;s/['\"]$//")
AUTHENTICATION=$(echo "${AUTHENTICATION}" | sed "s/^['\"]//;s/['\"]$//")

# 确保配置目录存在
mkdir -p "${CONFIG_DIR}"

# 静默复制 GeoIP 数据库
if [ -d "${GEODATA_DIR}" ]; then
    for file in "${GEODATA_DIR}"/*; do
        filename=$(basename "$file")
        target="${CONFIG_DIR}/${filename}"
        [ ! -f "${target}" ] && cp "$file" "${target}"
    done
fi

# 处理订阅逻辑
if [ -n "${SUB_URL}" ]; then
    log_info "🔗 检测到订阅地址: ${SUB_URL}"
    
    if [ -f "${CONFIG_FILE}" ]; then
        # 本地有配置：先尝试直连更新，失败再通过代理更新
        log_info "✅ 本地配置文件已存在"
        
        need_start=true
        config_updated=false
        
        # 1. 先尝试直连下载
        log_info "🔗 尝试直连更新订阅..."
        if download_subscription "${SUB_URL}" "${CONFIG_FILE}" "false"; then
            log_info "✅ 直连更新成功"
            config_updated=true
        else
            log_warn "⚠️ 直连下载失败，🔗 尝试通过代理更新..."
            
            # 2. 直连失败，启动 mihomo 后通过本地代理下载
            # 更新 secret（如果设置了 SECRET 环境变量）
            if [ -n "${SECRET}" ]; then
                update_secret "${CONFIG_FILE}" "${SECRET}"
            fi
            # 更新 allow-lan（如果设置了 ALLOW_LAN 环境变量）
            if [ -n "${ALLOW_LAN}" ]; then
                update_allow_lan "${CONFIG_FILE}" "${ALLOW_LAN}"
            fi
            if ! update_mode "${CONFIG_FILE}" "${MODE}"; then
                exit 1
            fi
            # 更新 authentication（如果设置了 AUTHENTICATION 环境变量）
            if [ -n "${AUTHENTICATION}" ]; then
                update_authentication "${CONFIG_FILE}" "${AUTHENTICATION}"
            fi
            # 确保统一延迟和并发连接
            ensure_unified_delay_and_tcp_concurrent "${CONFIG_FILE}"
            # 注入 tun 配置
            inject_tun "${CONFIG_FILE}" "${TUN_ENABLED}"
        inject_dns "${CONFIG_FILE}" "${DNS_OVERRIDE}"
            ensure_external_controller "${CONFIG_FILE}"
            
            if start_mihomo; then
                need_start=false
                log_info "⌛️ 等待代理服务就绪..."
                sleep 3
                
                # 通过本地代理更新订阅
                if download_subscription "${SUB_URL}" "${CONFIG_FILE}" "true"; then
                    log_info "✅ 通过代理更新成功，重启以应用新配置..."
                    config_updated=true
                else
                    log_warn "❌ 代理下载也失败，继续使用本地配置"
                fi
            else
                # mihomo 启动失败（本地配置有错误）
                log_error "❌ mihomo 启动失败，本地配置可能有错误"
                log_error "❌ 直连和本地代理都无法更新订阅，无法启动"
                
                # 尝试使用外部代理
                if [ -n "${DOWNLOAD_PROXY}" ]; then
                    log_info "🔗 尝试使用外部代理下载..."
                    if download_subscription "${SUB_URL}" "${CONFIG_FILE}" "true"; then
                        log_info "✅ 通过外部代理下载成功"
                        config_updated=true
                    else
                        log_error "❌ 外部代理下载也失败，无法启动"
                        exit 1
                    fi
                else
                    log_error "🔔 请尝试设置 DOWNLOAD_PROXY 环境变量以通过外部代理下载"
                    exit 1
                fi
            fi
        fi
        
        # 更新 secret 和 external-controller
        if [ -n "${SECRET}" ]; then
            update_secret "${CONFIG_FILE}" "${SECRET}"
        fi
        # 更新 allow-lan（如果设置了 ALLOW_LAN 环境变量）
        if [ -n "${ALLOW_LAN}" ]; then
            update_allow_lan "${CONFIG_FILE}" "${ALLOW_LAN}"
        fi
        # 更新 authentication（如果设置了 AUTHENTICATION 环境变量）
        if [ -n "${AUTHENTICATION}" ]; then
            update_authentication "${CONFIG_FILE}" "${AUTHENTICATION}"
        fi
        # 确保统一延迟和并发连接
        ensure_unified_delay_and_tcp_concurrent "${CONFIG_FILE}"
        # 注入 tun 配置
        inject_tun "${CONFIG_FILE}" "${TUN_ENABLED}"
        inject_dns "${CONFIG_FILE}" "${DNS_OVERRIDE}"
        ensure_external_controller "${CONFIG_FILE}"

        # ========== 新增：执行外部 Hook ==========
        if ! run_post_subscription_hooks "${CONFIG_FILE}"; then
            log_error "❌ 执行外部Hook失败"
            return 1
        fi
        # ========================================

        if ! update_mode "${CONFIG_FILE}" "${MODE}"; then
            exit 1
        fi

        # 启动或重启 mihomo
        if [ "${need_start}" = "true" ]; then
            if ! start_mihomo; then
                log_error "❌ mihomo 启动失败，请检查配置文件"
                exit 1
            fi
        elif [ "${config_updated}" = "true" ]; then
            restart_mihomo
        fi
    else
        # 本地无配置：尝试直连下载，失败则尝试使用外部代理
        log_info "🔔 本地配置文件不存在，尝试下载订阅..."
        
        # 先尝试直连
        if download_subscription "${SUB_URL}" "${CONFIG_FILE}" "false"; then
            log_info "🎉 直连下载成功"
        elif [ -n "${DOWNLOAD_PROXY}" ]; then
            # 直连失败，尝试使用外部代理
            log_info "❌ 直连下载失败，尝试使用外部代理..."
            if ! download_subscription "${SUB_URL}" "${CONFIG_FILE}" "true"; then
                log_error "❌ 订阅下载失败（直连和代理均失败），无法启动"
                log_error "❌ 请检查网络或设置 DOWNLOAD_PROXY 环境变量"
                exit 1
            fi
        else
            log_error "❌ 订阅下载失败且本地无配置文件，无法启动"
            log_error "🔔 如果订阅地址需要代理访问，请设置 DOWNLOAD_PROXY 环境变量"
            exit 1
        fi
        
        # 更新 secret（如果设置了 SECRET 环境变量）
        if [ -n "${SECRET}" ]; then
            update_secret "${CONFIG_FILE}" "${SECRET}"
        fi
        
        # 更新 allow-lan（如果设置了 ALLOW_LAN 环境变量）
        if [ -n "${ALLOW_LAN}" ]; then
            update_allow_lan "${CONFIG_FILE}" "${ALLOW_LAN}"
        fi

        # 更新 authentication（如果设置了 AUTHENTICATION 环境变量）
        if [ -n "${AUTHENTICATION}" ]; then
            update_authentication "${CONFIG_FILE}" "${AUTHENTICATION}"
        fi

        # 确保统一延迟和并发连接
        ensure_unified_delay_and_tcp_concurrent "${CONFIG_FILE}"

        # 注入 tun 配置
        inject_tun "${CONFIG_FILE}" "${TUN_ENABLED}"
        inject_dns "${CONFIG_FILE}" "${DNS_OVERRIDE}"

        # 确保 external-controller 配置正确
        ensure_external_controller "${CONFIG_FILE}"

        # ========== 新增：执行外部 Hook ==========
        if ! run_post_subscription_hooks "${CONFIG_FILE}"; then
            log_error "❌ 执行外部Hook失败"
            return 1
        fi
        # ========================================

        if ! update_mode "${CONFIG_FILE}" "${MODE}"; then
            exit 1
        fi

        # 启动 mihomo
        if ! start_mihomo; then
            log_error "❌ mihomo 启动失败，请检查下载的配置文件"
            exit 1
        fi
    fi
else
    log_info "🔔 未设置 SUB_URL，使用本地配置文件"
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "❌ 配置文件不存在: ${CONFIG_FILE}"
        log_error "🔔 请挂载配置文件或设置 SUB_URL 环境变量"
        exit 1
    fi
    
    # 更新 secret（如果设置了 SECRET 环境变量）
    if [ -n "${SECRET}" ]; then
        update_secret "${CONFIG_FILE}" "${SECRET}"
    fi
    
    # 更新 allow-lan（如果设置了 ALLOW_LAN 环境变量）
    if [ -n "${ALLOW_LAN}" ]; then
        update_allow_lan "${CONFIG_FILE}" "${ALLOW_LAN}"
    fi

    if ! update_mode "${CONFIG_FILE}" "${MODE}"; then
        exit 1
    fi

    # 更新 authentication（如果设置了 AUTHENTICATION 环境变量）
    if [ -n "${AUTHENTICATION}" ]; then
        update_authentication "${CONFIG_FILE}" "${AUTHENTICATION}"
    fi

    # 确保统一延迟和并发连接
    ensure_unified_delay_and_tcp_concurrent "${CONFIG_FILE}"

    # 注入 tun 配置
    inject_tun "${CONFIG_FILE}" "${TUN_ENABLED}"

    # 确保 external-controller 配置正确
    ensure_external_controller "${CONFIG_FILE}"

    # 启动 mihomo
    if ! start_mihomo; then
        log_error "❌ mihomo 启动失败，请检查配置文件"
        exit 1
    fi
fi

# 设置定时任务（如果设置了 SUB_CRON）
setup_cron "${SUB_CRON}"

# 等待 mihomo 进程
wait $(cat "${PID_FILE}")
