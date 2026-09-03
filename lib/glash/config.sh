#!/bin/bash

top_level_key_matches_awk='function matches_key(line, value) {
    if (line ~ /^[[:space:]]/ || line ~ /^[#%]/ || line ~ /^---([[:space:]]|$)/) return 0
    value = line
    sub(/[[:space:]]*:.*/, "", value)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    if (value ~ /^\047.*\047$/ || value ~ /^\".*\"$/) value = substr(value, 2, length(value) - 2)
    return value == target
}'

replace_top_level_scalar() {
    local config="$1"
    local key="$2"
    local rendered_value="$3"
    local temp_file

    temp_file=$(make_sibling_temp "${config}" scalar) || return 1
    if ! GLASH_AWK_REPLACEMENT="${key}: ${rendered_value}" LC_ALL=C awk -v target="${key}" "
        ${top_level_key_matches_awk}
        BEGIN { replacement = ENVIRON[\"GLASH_AWK_REPLACEMENT\"] }
        NR == 1 && substr(\$0, 1, 3) == \"\357\273\277\" {
            printf \"%s\", substr(\$0, 1, 3)
            \$0 = substr(\$0, 4)
        }
        !inserted && (\$0 ~ /^[[:space:]]*\$/ || \$0 ~ /^#/ || \$0 ~ /^%/ || \$0 ~ /^---([[:space:]]|\$)/) {
            print
            next
        }
        matches_key(\$0) {
            if (!inserted) print replacement
            inserted = 1
            next
        }
        !inserted {
            print replacement
            inserted = 1
        }
        { print }
        END { if (!inserted) print replacement }
    " "${config}" > "${temp_file}" || ! replace_file "${temp_file}" "${config}"; then
        rm -f "${temp_file}"
        return 1
    fi
    rm -f "${temp_file}"
}

remove_top_level_block() {
    local config="$1"
    local key="$2"
    local temp_file

    temp_file=$(make_sibling_temp "${config}" block) || return 1
    if ! LC_ALL=C awk -v target="${key}" "
        ${top_level_key_matches_awk}
        function is_top_level_key(line) {
            return line !~ /^[[:space:]]/ && line !~ /^[#%]/ && line !~ /^---([[:space:]]|\$)/ && line ~ /:/
        }
        matches_key(\$0) { skipping = 1; next }
        skipping && is_top_level_key(\$0) { skipping = 0 }
        !skipping { print }
    " "${config}" > "${temp_file}" || ! replace_file "${temp_file}" "${config}"; then
        rm -f "${temp_file}"
        return 1
    fi
    rm -f "${temp_file}"
}

has_top_level_key() {
    local config="$1"
    local key="$2"
    LC_ALL=C awk -v target="${key}" "${top_level_key_matches_awk} matches_key(\$0) { found = 1; exit } END { exit !found }" "${config}"
}

read_top_level_scalar() {
    local config="$1"
    local key="$2"
    LC_ALL=C awk -v target="${key}" "
        ${top_level_key_matches_awk}
        matches_key(\$0) {
            value = \$0
            sub(/^[^:]*:[[:space:]]*/, \"\", value)
            sub(/[[:space:]]*#.*/, \"\", value)
            gsub(/^[[:space:]\047\"]+|[[:space:]\047\"]+\$/, \"\", value)
            print value
            exit
        }
    " "${config}"
}

validate_config() {
    local file="$1"
    local file_size
    local key
    local has_port=false

    if [ ! -s "${file}" ]; then
        log_error "❌ 配置文件为空或不存在"
        return 1
    fi

    if LC_ALL=C grep -qiE '^[[:space:]]*(<!doctype[[:space:]]+html|<html)' "${file}"; then
        log_error "❌ 下载结果是 HTML，不是 Mihomo 配置"
        return 1
    fi

    for key in port socks-port mixed-port redir-port tproxy-port; do
        if has_top_level_key "${file}" "${key}"; then
            has_port=true
            break
        fi
    done
    if [ "${has_port}" != "true" ]; then
        log_error "❌ 配置文件缺少代理端口字段"
        return 1
    fi

    if ! has_top_level_key "${file}" proxies && ! has_top_level_key "${file}" proxy-providers; then
        log_error "❌ 配置文件缺少 proxies 或 proxy-providers 字段"
        return 1
    fi

    file_size=$(wc -c < "${file}" | tr -d '[:space:]')
    log_info "✅ 配置文件基础验证通过 (${file_size} bytes)"
}

validate_config_with_mihomo() {
    local file="$1"

    [ -x "${MIHOMO_BIN}" ] || return 0
    if ! SAFE_PATHS="${SAFE_PATHS:+${SAFE_PATHS}:}${UI_DIR}" \
        "${MIHOMO_BIN}" -t -d "${CONFIG_DIR}" -f "${file}"; then
        log_error "❌ Mihomo 拒绝该配置"
        return 1
    fi
}

update_secret() {
    local config="$1"
    local secret="$2"
    local rendered

    rendered=$(yaml_quote "${secret}") || {
        log_error "❌ SECRET 包含不支持的换行符"
        return 1
    }
    log_info "🔗 正在更新配置文件中的 secret..."
    replace_top_level_scalar "${config}" secret "${rendered}" || return 1
    log_info "✅ secret 已更新"
}

update_authentication() {
    local config="$1"
    local auth="$2"
    local item rendered username password
    local -a entries

    [ -z "${auth}" ] && return 0
    log_info "🔗 正在更新配置文件中的 authentication..."
    remove_top_level_block "${config}" authentication || return 1

    IFS=',' read -r -a entries <<< "${auth}"
    if [ "${#entries[@]}" -eq 0 ]; then
        log_error "❌ AUTHENTICATION 未包含有效凭据"
        return 1
    fi

    printf 'authentication:\n' >> "${config}" || return 1
    for item in "${entries[@]}"; do
        item=$(printf '%s' "${item}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        username=${item%%:*}
        password=${item#*:}
        if [ -z "${item}" ] || [[ "${item}" != *:* ]] || [ -z "${username}" ] || [ -z "${password}" ]; then
            log_error "❌ AUTHENTICATION 必须使用 username:password 格式"
            return 1
        fi
        rendered=$(yaml_quote "${item}") || return 1
        printf '  - %s\n' "${rendered}" >> "${config}" || return 1
    done
    log_info "✅ authentication 已更新"
}

update_proxy_ports() {
    local config="$1"
    local mapping env_name key value

    for mapping in HTTP_PORT:port SOCKS_PORT:socks-port MIXED_PORT:mixed-port; do
        IFS=: read -r env_name key <<< "${mapping}"
        value=${!env_name}
        [ -z "${value}" ] && continue
        validate_optional_port "${env_name}" "${value}" || return 1
        log_info "🔗 正在将 ${key} 覆写为 ${value}..."
        replace_top_level_scalar "${config}" "${key}" "${value}" || return 1
    done
}

ensure_unified_delay_and_tcp_concurrent() {
    local config="$1"
    local force_override="${FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT:-false}"
    local key

    log_info "🔗 正在检查 unified-delay 和 tcp-concurrent..."
    for key in unified-delay tcp-concurrent; do
        if ! has_top_level_key "${config}" "${key}"; then
            replace_top_level_scalar "${config}" "${key}" true || return 1
        elif [ "${force_override}" = "true" ]; then
            replace_top_level_scalar "${config}" "${key}" true || return 1
        fi
    done
    log_info "✅ unified-delay 和 tcp-concurrent 已检查"
}

inject_tun() {
    local config="$1"
    local tun_enabled="$2"
    local auto_redirect="${3:-}"

    [ -z "${tun_enabled}" ] && return 0
    validate_optional_boolean TUN_ENABLED "${tun_enabled}" || return 1
    log_info "🔗 正在更新配置文件中的 tun 配置..."
    remove_top_level_block "${config}" tun || return 1

    if [ "${tun_enabled}" = "true" ]; then
        [ -n "${auto_redirect}" ] || auto_redirect=true
        validate_optional_boolean TUN_AUTO_REDIRECT "${auto_redirect}" || return 1
        printf '%s\n' \
            'tun:' \
            '  enable: true' \
            '  stack: mixed' \
            '  auto-route: true' \
            "  auto-redirect: ${auto_redirect}" \
            '  auto-detect-interface: true' >> "${config}" || return 1
        log_info "✅ tun 模式已启用"
    else
        printf '%s\n' 'tun:' '  enable: false' >> "${config}" || return 1
        log_info "✅ tun 模式已显式关闭"
    fi
}

inject_dns() {
    local config="$1"
    local dns_override="$2"

    [ -z "${dns_override}" ] && return 0
    validate_optional_boolean DNS_OVERRIDE "${dns_override}" || return 1
    [ "${dns_override}" = "false" ] && return 0

    log_info "🔗 正在覆写配置文件中的 DNS 配置..."
    remove_top_level_block "${config}" dns || return 1
    printf '%s\n' \
        'dns:' \
        '  enable: true' \
        '  listen: "0.0.0.0:1053"' \
        '  prefer-h3: true' \
        '  use-hosts: true' \
        '  use-system-hosts: true' \
        '  respect-rules: false' \
        '  ipv6: true' \
        '  default-nameserver:' \
        '    - "223.5.5.5"' \
        '  enhanced-mode: "fake-ip"' \
        '  fake-ip-range: "198.18.0.1/16"' \
        '  fake-ip-filter:' \
        '    - "*.lan"' \
        '    - "localhost.ptlogin2.qq.com"' \
        '  nameserver-policy:' \
        '    geosite:cn: "https://doh.pub/dns-query"' \
        '    geosite:gfw: "tls://1.1.1.1"' \
        '  nameserver:' \
        '    - "https://doh.pub/dns-query"' \
        '    - "https://dns.alidns.com/dns-query"' \
        '    - "system://"' \
        '  fallback:' \
        '    - "tls://8.8.4.4"' \
        '    - "tls://1.1.1.1"' \
        '  proxy-server-nameserver:' \
        '    - "https://doh.pub/dns-query"' \
        '  fallback-filter:' \
        '    geoip: true' \
        '    geoip-code: "CN"' \
        '    ipcidr:' \
        '      - "240.0.0.0/4"' >> "${config}" || return 1
    log_info "✅ DNS 配置已覆写"
}

update_allow_lan() {
    local config="$1"
    local allow_lan="$2"

    [ -z "${allow_lan}" ] && return 0
    validate_optional_boolean ALLOW_LAN "${allow_lan}" || return 1
    log_info "🔗 正在更新配置文件中的 allow-lan..."
    replace_top_level_scalar "${config}" allow-lan "${allow_lan}" || return 1
    log_info "✅ allow-lan 已更新为 ${allow_lan}"
}

update_mode() {
    local config="$1"
    local mode="$2"

    [ -z "${mode}" ] && return 0
    case "${mode}" in
        rule|global|direct) ;;
        *)
            log_warn "❌ MODE 仅支持 rule、global 或 direct，保持原配置"
            return 0
            ;;
    esac
    log_info "🔗 正在更新配置文件中的代理模式..."
    replace_top_level_scalar "${config}" mode "${mode}" || return 1
    log_info "✅ 代理模式已更新为 ${mode}"
}

ensure_external_controller() {
    local config="$1"
    replace_top_level_scalar "${config}" external-controller '0.0.0.0:9090'
}

apply_config_overrides() {
    local config="$1"
    local force_secret="${2:-false}"
    local run_hooks="${3:-false}"
    local ensure_defaults="${4:-true}"

    if [ "${force_secret}" = "true" ] || [ -n "${SECRET}" ]; then
        update_secret "${config}" "${SECRET}" || return 1
    fi
    update_proxy_ports "${config}" || return 1
    update_allow_lan "${config}" "${ALLOW_LAN}" || return 1
    update_authentication "${config}" "${AUTHENTICATION}" || return 1
    if [ "${ensure_defaults}" = "true" ]; then
        ensure_unified_delay_and_tcp_concurrent "${config}" || return 1
    fi
    inject_tun "${config}" "${TUN_ENABLED}" "${TUN_AUTO_REDIRECT}" || return 1
    inject_dns "${config}" "${DNS_OVERRIDE}" || return 1
    if [ "${ensure_defaults}" = "true" ]; then
        ensure_external_controller "${config}" || return 1
    fi
    if [ "${run_hooks}" = "true" ]; then
        run_post_subscription_hooks "${config}" || return 1
    fi
    update_mode "${config}" "${MODE}" || return 1
    if [ "${force_secret}" = "true" ]; then
        update_secret "${config}" "${SECRET}" || return 1
        ensure_external_controller "${config}" || return 1
    fi
}

prepare_existing_config() {
    local config="$1"
    local ensure_defaults="${2:-false}"
    local temp_file backup_file

    temp_file=$(make_sibling_temp "${config}" prepared) || return 1
    if ! cp -p "${config}" "${temp_file}" || \
        ! apply_config_overrides "${temp_file}" false false "${ensure_defaults}" || \
        ! validate_config_with_mihomo "${temp_file}"; then
        rm -f "${temp_file}"
        log_error "❌ 配置预处理失败，原文件保持不变"
        return 1
    fi

    if ! cmp -s "${temp_file}" "${config}"; then
        backup_file=$(make_sibling_temp "${config}" backup) || {
            rm -f "${temp_file}"
            return 1
        }
        if ! cp -p "${config}" "${backup_file}"; then
            rm -f "${temp_file}" "${backup_file}"
            return 1
        fi
        if ! replace_file "${temp_file}" "${config}"; then
            if replace_file "${backup_file}" "${config}"; then
                rm -f "${backup_file}"
            else
                log_error "❌ 原配置恢复失败，备份保留在 ${backup_file}"
            fi
            rm -f "${temp_file}"
            return 1
        fi
        rm -f "${backup_file}"
    fi
    rm -f "${temp_file}"
}
