#!/bin/bash

install_geodata() {
    local file target
    local -a files

    [ -d "${GEODATA_DIR}" ] || return 0
    shopt -s nullglob
    files=("${GEODATA_DIR}"/*)
    shopt -u nullglob
    for file in "${files[@]}"; do
        [ -f "${file}" ] || continue
        target="${CONFIG_DIR}/$(basename "${file}")"
        [ -f "${target}" ] || cp "${file}" "${target}" || return 1
    done
}

start_from_existing_config() {
    local ensure_defaults="${1:-false}"
    prepare_existing_config "${CONFIG_FILE}" "${ensure_defaults}" || return 1
    start_mihomo
}

start_subscription_mode_with_existing_config() {
    local original_config

    original_config=$(make_sibling_temp "${CONFIG_FILE}" startup) || return 1
    cp -p "${CONFIG_FILE}" "${original_config}" || {
        rm -f "${original_config}"
        return 1
    }

    log_info "🔗 尝试直连更新订阅..."
    if install_subscription_config direct false; then
        if start_mihomo; then
            rm -f "${original_config}"
            return 0
        fi
        log_warn "⚠️ 新订阅无法启动，回退到原配置"
        replace_file "${original_config}" "${CONFIG_FILE}" || {
            rm -f "${original_config}"
            return 1
        }
    fi

    rm -f "${original_config}"
    log_warn "⚠️ 直连更新不可用，先使用本地配置启动"
    if start_from_existing_config true; then
        log_info "⌛️ 等待本地代理服务就绪..."
        sleep 3
        if ! update_subscription; then
            log_warn "⚠️ 代理更新失败，继续使用当前配置"
        fi
        return 0
    fi

    if [ -n "${DOWNLOAD_PROXY}" ]; then
        log_warn "⚠️ 本地配置无法启动，尝试使用外部代理获取订阅"
        if install_subscription_config external false && start_mihomo; then
            return 0
        fi
    fi
    log_error "❌ 直连、本地配置和外部代理均不可用"
    return 1
}

start_subscription_mode_without_config() {
    log_info "🔔 本地配置不存在，尝试下载订阅"
    if install_subscription_config direct false; then
        start_mihomo
        return
    fi
    if [ -n "${DOWNLOAD_PROXY}" ] && install_subscription_config external false; then
        start_mihomo
        return
    fi
    log_error "❌ 无法获取可用订阅配置"
    return 1
}

start_application() {
    if [ -n "${SUB_URL}" ]; then
        log_info "🔗 已配置订阅地址"
        if [ -f "${CONFIG_FILE}" ]; then
            start_subscription_mode_with_existing_config
        else
            start_subscription_mode_without_config
        fi
        return
    fi

    log_info "🔔 未设置 SUB_URL，使用本地配置文件"
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "❌ 配置文件不存在: ${CONFIG_FILE}"
        return 1
    fi
    start_from_existing_config false
}

main() {
    log_info "🚀 glash 启动中 🚀"
    load_environment || return 1
    mkdir -p "${CONFIG_DIR}" || return 1
    install_geodata || return 1
    install_signal_handlers
    start_application || return 1
    setup_cron "${SUB_CRON}" || {
        stop_mihomo || true
        return 1
    }
    wait_for_mihomo
}
