#!/bin/bash

start_mihomo() {
    local pid

    log_info "🚀 正在启动 mihomo..."
    SAFE_PATHS="${SAFE_PATHS:+${SAFE_PATHS}:}${UI_DIR}" \
        "${MIHOMO_BIN}" -d "${CONFIG_DIR}" -ext-ui "${UI_DIR}" &
    pid=$!

    if ! printf '%s\n' "${pid}" > "${PID_FILE}"; then
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
        log_error "❌ 无法写入 mihomo PID 文件"
        return 1
    fi

    sleep 2
    if ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}" 2>/dev/null || true
        rm -f "${PID_FILE}"
        log_error "❌ mihomo 启动失败，请检查配置文件"
        return 1
    fi
    log_info "🎉 mihomo 已启动，PID: ${pid}"
}

stop_mihomo() {
    local pid count

    [ -f "${PID_FILE}" ] || return 0
    pid=$(cat "${PID_FILE}")
    case "${pid}" in
        ""|*[!0-9]*)
            log_error "❌ PID 文件内容无效"
            return 1
            ;;
    esac

    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || return 1
        count=0
        while kill -0 "${pid}" 2>/dev/null && [ "${count}" -lt 10 ]; do
            sleep 1
            count=$((count + 1))
        done
        if kill -0 "${pid}" 2>/dev/null; then
            log_warn "⚠️ mihomo 未正常退出，强制终止"
            kill -9 "${pid}" 2>/dev/null || return 1
        fi
        wait "${pid}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
}

restart_mihomo() {
    log_info "🔄 正在重启 mihomo..."
    stop_mihomo || return 1
    start_mihomo || return 1
    log_info "🎉 mihomo 重启完成"
}

check_mihomo_controller() {
    local controller_secret="${1:-}"
    local request_args=(-fsS --noproxy '*' --connect-timeout 5 --max-time 10)

    if [ -n "${controller_secret}" ]; then
        request_args+=(-H "Authorization: Bearer ${controller_secret}")
    fi
    curl "${request_args[@]}" 'http://127.0.0.1:9090/version' >/dev/null
}

reload_mihomo_config() {
    local controller_secret="${1:-${SECRET:-}}"
    local request_args=(
        -fsS --noproxy '*' --connect-timeout 5 --max-time 30
        -X PUT -H 'Content-Type: application/json'
        -d '{"path":"","payload":""}'
    )
    local attempt

    if [ -n "${controller_secret}" ]; then
        request_args+=(-H "Authorization: Bearer ${controller_secret}")
    fi
    for attempt in 1 2; do
        log_info "🔄 正在热加载 mihomo 配置（${attempt}/2）..."
        if curl "${request_args[@]}" 'http://127.0.0.1:9090/configs?force=true'; then
            log_info "🎉 mihomo 配置热加载完成"
            return 0
        fi
        [ "${attempt}" -eq 2 ] || sleep 1
    done
    log_error "❌ mihomo 配置热加载失败，保持当前进程运行"
    return 1
}

wait_for_mihomo() {
    local pid status

    if [ ! -f "${PID_FILE}" ]; then
        log_error "❌ mihomo PID 文件不存在"
        return 1
    fi
    pid=$(cat "${PID_FILE}")
    case "${pid}" in
        ""|*[!0-9]*)
            log_error "❌ mihomo PID 文件内容无效"
            return 1
            ;;
    esac
    if wait "${pid}"; then
        status=0
    else
        status=$?
    fi
    rm -f "${PID_FILE}"
    return "${status}"
}

handle_signal() {
    log_info "🔔 收到终止信号，正在关闭..."
    stop_mihomo || true
    exit 0
}

install_signal_handlers() {
    trap handle_signal SIGTERM SIGINT
}
