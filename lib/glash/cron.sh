#!/bin/bash

validate_cron_schedule() {
    local schedule="$1"
    local field
    local -a fields

    reject_multiline_value SUB_CRON "${schedule}" || return 1
    read -r -a fields <<< "${schedule}"
    if [ "${#fields[@]}" -ne 5 ]; then
        log_error "❌ SUB_CRON 必须是包含 5 个字段的 cron 表达式"
        return 1
    fi
    for field in "${fields[@]}"; do
        case "${field}" in
            ""|*[!0-9A-Za-z*/,-]*)
                log_error "❌ SUB_CRON 含有非法字符"
                return 1
                ;;
        esac
    done
}

write_update_script() {
    local target='/app/update_sub.sh'
    local name

    printf '%s\n' '#!/bin/bash' 'set -u' > "${target}" || return 1
    for name in SUB_URL SECRET ALLOW_LAN MODE TUN_ENABLED DNS_OVERRIDE SUB_USER_AGENT AUTHENTICATION DOWNLOAD_PROXY FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT; do
        printf 'export %s=%q\n' "${name}" "${!name}" >> "${target}" || return 1
    done
    printf '%s\n' 'source /app/start.sh' 'update_subscription' >> "${target}" || return 1
    chmod 700 "${target}"
}

setup_cron() {
    local cron_schedule="$1"

    if [ -z "${cron_schedule}" ]; then
        log_info "🔔 未设置 SUB_CRON，跳过定时任务配置"
        return 0
    fi
    validate_cron_schedule "${cron_schedule}" || return 1
    log_info "🔗 设置订阅更新定时任务: ${cron_schedule}"
    write_update_script || {
        log_error "❌ 无法创建订阅更新脚本"
        return 1
    }
    printf '%s /app/update_sub.sh >> /var/log/subscription.log 2>&1\n' "${cron_schedule}" > "${CRON_FILE}" || {
        log_error "❌ 无法写入 cron 配置"
        return 1
    }
    crond -b -l 8 || {
        log_error "❌ crond 启动失败"
        return 1
    }
    log_info "🎉 定时任务已启动"
}
