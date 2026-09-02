#!/bin/bash

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
: "${FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT:=false}"
: "${SAFE_PATHS:=}"

strip_outer_quotes() {
    local value="$1"
    if [ "${#value}" -ge 2 ]; then
        case "${value}" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
    fi
    printf '%s' "${value}"
}

reject_multiline_value() {
    local name="$1"
    local value="$2"
    if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
        log_error "❌ ${name} 不允许包含换行符"
        return 1
    fi
}

validate_optional_boolean() {
    local name="$1"
    local value="$2"
    case "${value}" in
        ""|true|false) return 0 ;;
        *)
            log_error "❌ ${name} 仅支持 true 或 false"
            return 1
            ;;
    esac
}

load_environment() {
    local name
    for name in SUB_URL SECRET SUB_CRON DOWNLOAD_PROXY ALLOW_LAN MODE TUN_ENABLED DNS_OVERRIDE SUB_USER_AGENT AUTHENTICATION FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT; do
        reject_multiline_value "${name}" "${!name}" || return 1
        printf -v "${name}" '%s' "$(strip_outer_quotes "${!name}")"
        reject_multiline_value "${name}" "${!name}" || return 1
    done

    case "${MODE}" in
        ""|rule|global|direct) ;;
        *)
            log_error "❌ MODE 仅支持 rule、global 或 direct"
            return 1
            ;;
    esac

    validate_optional_boolean ALLOW_LAN "${ALLOW_LAN}" || return 1
    validate_optional_boolean TUN_ENABLED "${TUN_ENABLED}" || return 1
    validate_optional_boolean DNS_OVERRIDE "${DNS_OVERRIDE}" || return 1
    validate_optional_boolean FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT "${FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT}" || return 1
}
