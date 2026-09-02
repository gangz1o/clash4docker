#!/bin/bash

CONFIG_DIR="${CONFIG_DIR:-${MIHOMO_CONFIG_DIR:-/root/.config/mihomo}}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.yaml}"
HOOK_DIR="${HOOK_DIR:-/app/hooks.d}"
UI_DIR="${UI_DIR:-/app/ui}"
GEODATA_DIR="${GEODATA_DIR:-/app/geodata}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
PID_FILE="${PID_FILE:-/var/run/mihomo.pid}"
UPDATE_LOCK_FILE="${UPDATE_LOCK_FILE:-/var/run/glash-subscription-update.lock}"
MIHOMO_BIN="${MIHOMO_BIN:-/app/mihomo}"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

log_info() {
    printf '%b[INFO]%b %b%s%b %s\n' "${GREEN}" "${RESET}" "${CYAN}" "$(date '+%Y-%m-%d %H:%M:%S')" "${RESET}" "$*"
}

log_warn() {
    printf '%b[WARN]%b %b%s%b %s\n' "${YELLOW}" "${RESET}" "${CYAN}" "$(date '+%Y-%m-%d %H:%M:%S')" "${RESET}" "$*" >&2
}

log_error() {
    printf '%b[ERROR]%b %b%s%b %s\n' "${RED}" "${RESET}" "${CYAN}" "$(date '+%Y-%m-%d %H:%M:%S')" "${RESET}" "$*" >&2
}

make_sibling_temp() {
    local target="$1"
    local label="${2:-tmp}"
    mktemp "${target}.${label}.XXXXXX"
}

replace_file() {
    local source_file="$1"
    local target_file="$2"

    if ! cp -f "${source_file}" "${target_file}"; then
        log_error "❌ 文件写入失败: ${target_file}"
        return 1
    fi
}

yaml_quote() {
    local value="$1"
    if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
        return 1
    fi
    value=${value//\'/\'\'}
    printf "'%s'" "${value}"
}
