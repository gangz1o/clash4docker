#!/bin/bash

local_http_proxy_url() {
    local port

    port=$(read_top_level_scalar "${CONFIG_FILE}" port 2>/dev/null || true)
    [ -n "${port}" ] || port=$(read_top_level_scalar "${CONFIG_FILE}" mixed-port 2>/dev/null || true)
    case "${port}" in
        ""|*[!0-9]*) port=7890 ;;
    esac
    [ "${#port}" -le 5 ] || port=7890
    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        port=7890
    fi
    printf 'http://127.0.0.1:%s' "${port}"
}

download_subscription() {
    local url="$1"
    local output="$2"
    local proxy_mode="${3:-direct}"
    local temp_file proxy_url attempt
    local max_retries=3
    local retry_delay=5
    local -a request_args=(-fsSL)

    case "${url}" in
        http://*|https://*) ;;
        *)
            log_error "❌ SUB_URL 仅支持 http:// 或 https://"
            return 1
            ;;
    esac

    case "${proxy_mode}" in
        false|direct)
            log_info "🔗 使用直连下载订阅"
            ;;
        true|local)
            proxy_url=$(local_http_proxy_url)
            request_args+=(--proxy "${proxy_url}")
            log_info "🔗 使用本地代理下载订阅"
            ;;
        external)
            if [ -z "${DOWNLOAD_PROXY}" ]; then
                log_error "❌ 未设置 DOWNLOAD_PROXY"
                return 1
            fi
            proxy_url="${DOWNLOAD_PROXY}"
            request_args+=(--proxy "${proxy_url}")
            log_info "🔗 使用外部代理下载订阅"
            ;;
        *)
            log_error "❌ 未知下载模式: ${proxy_mode}"
            return 1
            ;;
    esac

    request_args+=(
        -A "${SUB_USER_AGENT:-clash.meta}"
        --connect-timeout 60 --max-time 300 --retry 2 --retry-delay 3
    )

    temp_file=$(mktemp "${TMPDIR:-/tmp}/glash-subscription.XXXXXX") || return 1
    for ((attempt = 1; attempt <= max_retries; attempt++)); do
        : > "${temp_file}"
        log_info "🔗 下载尝试 ${attempt}/${max_retries}..."
        if curl "${request_args[@]}" -o "${temp_file}" --url "${url}" && \
            validate_config "${temp_file}" && \
            replace_file "${temp_file}" "${output}"; then
            rm -f "${temp_file}"
            log_info "✅ 订阅配置下载成功"
            return 0
        fi
        [ "${attempt}" -eq "${max_retries}" ] || sleep "${retry_delay}"
    done
    rm -f "${temp_file}"
    log_error "❌ 订阅配置下载失败（已重试 ${max_retries} 次）"
    return 1
}

build_subscription_candidate() {
    local candidate="$1"
    local proxy_mode="$2"
    local force_secret="${3:-false}"

    download_subscription "${SUB_URL}" "${candidate}" "${proxy_mode}" || return 1
    apply_config_overrides "${candidate}" "${force_secret}" true true || return 1
    validate_config "${candidate}" || return 1
    validate_config_with_mihomo "${candidate}" || return 1
}

install_subscription_config() {
    local proxy_mode="$1"
    local force_secret="${2:-false}"
    local candidate backup_file=''

    candidate=$(make_sibling_temp "${CONFIG_FILE}" candidate) || return 1
    if ! build_subscription_candidate "${candidate}" "${proxy_mode}" "${force_secret}"; then
        rm -f "${candidate}"
        log_error "❌ 新订阅未安装，原配置保持不变"
        return 1
    fi

    if [ -f "${CONFIG_FILE}" ]; then
        backup_file=$(make_sibling_temp "${CONFIG_FILE}" backup) || {
            rm -f "${candidate}"
            return 1
        }
        cp -p "${CONFIG_FILE}" "${backup_file}" || {
            rm -f "${candidate}" "${backup_file}"
            return 1
        }
    fi
    if ! replace_file "${candidate}" "${CONFIG_FILE}"; then
        if [ -n "${backup_file}" ]; then
            if replace_file "${backup_file}" "${CONFIG_FILE}"; then
                rm -f "${backup_file}"
            else
                log_error "❌ 原配置恢复失败，备份保留在 ${backup_file}"
            fi
        else
            rm -f "${CONFIG_FILE}"
        fi
        rm -f "${candidate}"
        log_error "❌ 新订阅写入失败，原配置保持不变"
        return 1
    fi
    rm -f "${candidate}"
    [ -n "${backup_file}" ] && rm -f "${backup_file}"
}

restore_config_backup() {
    local backup_file="$1"
    if replace_file "${backup_file}" "${CONFIG_FILE}"; then
        rm -f "${backup_file}"
        log_warn "⚠️ 已恢复热加载前的配置文件"
        return 0
    fi
    log_error "❌ 配置文件恢复失败，备份保留在 ${backup_file}"
    return 1
}

restore_and_reload_config() {
    local backup_file="$1"
    local controller_secret="$2"
    restore_config_backup "${backup_file}" || return 1
    reload_mihomo_config "${controller_secret}" || {
        log_error "❌ 旧配置补偿加载失败，运行态可能与磁盘配置不一致"
        return 1
    }
}

perform_subscription_update() {
    local controller_secret="${SECRET:-}"
    local config_backup candidate

    if [ -z "${SUB_URL}" ]; then
        log_warn "⚠️ 未设置 SUB_URL，跳过订阅更新"
        return 1
    fi
    if ! check_mihomo_controller "${controller_secret}"; then
        log_error "❌ 无法访问 Mihomo Controller；请检查 SECRET 是否匹配"
        return 1
    fi

    config_backup=$(make_sibling_temp "${CONFIG_FILE}" backup) || return 1
    candidate=$(make_sibling_temp "${CONFIG_FILE}" candidate) || {
        rm -f "${config_backup}"
        return 1
    }
    if ! cp -p "${CONFIG_FILE}" "${config_backup}"; then
        rm -f "${config_backup}" "${candidate}"
        log_error "❌ 无法备份当前配置，取消订阅更新"
        return 1
    fi

    log_info "🔗 开始更新订阅..."
    if ! build_subscription_candidate "${candidate}" local true; then
        rm -f "${config_backup}" "${candidate}"
        log_error "❌ 订阅更新失败，当前配置保持不变"
        return 1
    fi
    if ! replace_file "${candidate}" "${CONFIG_FILE}"; then
        rm -f "${candidate}"
        restore_config_backup "${config_backup}" || true
        return 1
    fi
    rm -f "${candidate}"

    if ! reload_mihomo_config "${controller_secret}"; then
        restore_and_reload_config "${config_backup}" "${controller_secret}" || true
        return 1
    fi
    rm -f "${config_backup}"
    log_info "🎉 订阅更新完成"
}

update_subscription() {
    local status

    if ! exec 9>"${UPDATE_LOCK_FILE}"; then
        log_error "❌ 无法创建订阅更新锁: ${UPDATE_LOCK_FILE}"
        return 1
    fi
    if ! flock -n 9; then
        log_warn "⚠️ 已有订阅更新正在执行，跳过本次任务"
        exec 9>&-
        return 1
    fi
    if perform_subscription_update; then
        status=0
    else
        status=$?
    fi
    exec 9>&-
    return "${status}"
}
