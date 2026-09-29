#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${REPO_DIR}/start.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT

assert_mode() {
    local expected="$1"
    local config="$2"
    local actual
    actual=$(awk -F ': *' '/^mode:/ { print $2; exit }' "${config}")
    [ "${actual}" = "${expected}" ]
}

CONFIG_FILE="${TEST_DIR}/config.yaml"
cat > "${CONFIG_FILE}" <<'EOF'
mixed-port: 7890
mode: rule
proxies: []
EOF

update_mode "${CONFIG_FILE}" "global"
assert_mode "global" "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'EOF'
mixed-port: 7890
mode : rule
'mode': global
"mode": rule
proxies: []
EOF

update_mode "${CONFIG_FILE}" "direct"
assert_mode "direct" "${CONFIG_FILE}"
[ "$(grep -c 'mode' "${CONFIG_FILE}")" -eq 1 ]

cat > "${CONFIG_FILE}" <<'EOF'
# subscription config
%YAML 1.2
---
mode: rule
mixed-port: 7890
proxies: []
EOF

update_mode "${CONFIG_FILE}" "global"
[ "$(sed -n '2p' "${CONFIG_FILE}")" = "%YAML 1.2" ]
[ "$(sed -n '3p' "${CONFIG_FILE}")" = "---" ]
[ "$(sed -n '4p' "${CONFIG_FILE}")" = "mode: global" ]
[ "$(grep -c '^mode:' "${CONFIG_FILE}")" -eq 1 ]

printf '\357\273\277---\nmode: rule\nmixed-port: 7890\nproxies: []\n' > "${CONFIG_FILE}"
update_mode "${CONFIG_FILE}" "direct"
[ "$(LC_ALL=C head -c 3 "${CONFIG_FILE}" | od -An -tx1 | tr -d ' ')" = "efbbbf" ]
assert_mode "direct" "${CONFIG_FILE}"

cp "${CONFIG_FILE}" "${TEST_DIR}/before.yaml"
update_mode "${CONFIG_FILE}" ""
cmp "${TEST_DIR}/before.yaml" "${CONFIG_FILE}"

update_mode "${CONFIG_FILE}" "invalid"
cmp "${TEST_DIR}/before.yaml" "${CONFIG_FILE}"

# IPv6 覆写复用与 MODE 相同的顶层标量变换，并同步修改 DNS 直接子键。
(
    CONFIG_FILE="${TEST_DIR}/ipv6.yaml"
    for indent in '  ' '    '; do
        printf '%s\n' 'ipv6: false' "'ipv6': false" 'dns:' \
            "${indent}enable: true" "${indent}'ipv6': false" \
            "${indent}nameserver: [223.5.5.5]" \
            "${indent}nameserver-policy:" "${indent}  ipv6: nested-value" \
            'proxies: [{name: node, ipv6: false}]' > "${CONFIG_FILE}"
        for value in true false; do
            update_ipv6 "${CONFIG_FILE}" "${value}"
            printf '%s\n' "ipv6: ${value}" 'dns:' "${indent}ipv6: ${value}" \
                "${indent}enable: true" "${indent}nameserver: [223.5.5.5]" \
                "${indent}nameserver-policy:" "${indent}  ipv6: nested-value" \
                'proxies: [{name: node, ipv6: false}]' > "${TEST_DIR}/expected.yaml"
            cmp "${TEST_DIR}/expected.yaml" "${CONFIG_FILE}"
            update_ipv6 "${CONFIG_FILE}" "${value}"
            cmp "${TEST_DIR}/expected.yaml" "${CONFIG_FILE}"
        done
    done

    # 缺少 DNS 或 ipv6 时补齐；支持空映射、引号键、注释和文档头。
    for dns in '' 'dns:' 'dns: {}' "'dns': # comment"; do
        printf '%s\n' '%YAML 1.2' '---' 'mixed-port: 7890' 'proxies: []' "${dns}" > "${CONFIG_FILE}"
        update_ipv6 "${CONFIG_FILE}" true
        grep -qx 'ipv6: true' "${CONFIG_FILE}"
        grep -qx '  ipv6: true' "${CONFIG_FILE}"
        [ "$(sed -n '1p' "${CONFIG_FILE}")" = '%YAML 1.2' ]
        [ "$(sed -n '2p' "${CONFIG_FILE}")" = '---' ]
        ! grep -q 'enable:' "${CONFIG_FILE}"
    done
    printf '\357\273\277dns:\n    enable: true\nproxies: []\n' > "${CONFIG_FILE}"
    update_ipv6 "${CONFIG_FILE}" false
    [ "$(LC_ALL=C head -c 3 "${CONFIG_FILE}" | od -An -tx1 | tr -d ' ')" = 'efbbbf' ]
    grep -qx '    ipv6: false' "${CONFIG_FILE}"

    cp "${CONFIG_FILE}" "${TEST_DIR}/ipv6-before.yaml"
    update_ipv6 "${CONFIG_FILE}" ''
    cmp "${TEST_DIR}/ipv6-before.yaml" "${CONFIG_FILE}"
    for value in maybe TRUE 1 $'true\nfalse'; do
        if update_ipv6 "${CONFIG_FILE}" "${value}"; then exit 1; fi
        cmp "${TEST_DIR}/ipv6-before.yaml" "${CONFIG_FILE}"
        if ( IPV6_ENABLED="${value}"; load_environment ); then exit 1; fi
    done
    for value in true false '"true"' "'false'" ''; do
        ( IPV6_ENABLED="${value}"; load_environment )
    done

    # 不支持的 DNS 结构报错，不能只改顶层而留下不一致的配置。
    for dns in 'dns: {enable: true, ipv6: true}' 'dns: *defaults' $'dns:\n  ipv6: true\ndns:\n  ipv6: false'; do
        printf '%s\n' 'ipv6: true' "${dns}" > "${CONFIG_FILE}"
        cp "${CONFIG_FILE}" "${TEST_DIR}/ipv6-before.yaml"
        if update_ipv6 "${CONFIG_FILE}" false; then exit 1; fi
        cmp "${TEST_DIR}/ipv6-before.yaml" "${CONFIG_FILE}"
    done

    # 本地预处理在 DNS_OVERRIDE 之后应用 IPv6 开关。
    MIHOMO_BIN="${TEST_DIR}/missing-mihomo"
    DNS_OVERRIDE=true
    for value in false true; do
        IPV6_ENABLED="${value}"
        printf '%s\n' 'mixed-port: 7890' 'proxies: []' > "${CONFIG_FILE}"
        prepare_existing_config "${CONFIG_FILE}" false
        grep -qx "ipv6: ${value}" "${CONFIG_FILE}"
        grep -qx "  ipv6: ${value}" "${CONFIG_FILE}"
        grep -qx '  enable: true' "${CONFIG_FILE}"
    done

    # 订阅候选配置和独立运行的更新脚本必须保留开关。
    DNS_OVERRIDE=''
    HOOK_DIR="${TEST_DIR}/missing-hooks"
    SUB_URL='https://example.invalid/sub'
    download_subscription() {
        printf '%s\n' 'mixed-port: 7890' 'proxies: []' 'ipv6: true' 'dns:' '  enable: true' > "$2"
    }
    UPDATE_SCRIPT="${TEST_DIR}/update_sub.sh"
    for value in false true; do
        IPV6_ENABLED="${value}"
        build_subscription_candidate "${CONFIG_FILE}" direct false
        grep -qx "ipv6: ${value}" "${CONFIG_FILE}"
        grep -qx "  ipv6: ${value}" "${CONFIG_FILE}"
        write_update_script
        sed '/^source /,$d' "${UPDATE_SCRIPT}" > "${TEST_DIR}/exports.sh"
        actual=$(env -u IPV6_ENABLED bash -c 'source "$1"; printf "%s" "$IPV6_ENABLED"' bash "${TEST_DIR}/exports.sh")
        [ "${actual}" = "${value}" ]
    done

    cp "${CONFIG_FILE}" "${TEST_DIR}/ipv6-before.yaml"
    replace_file() { return 1; }
    if update_ipv6 "${CONFIG_FILE}" false; then exit 1; fi
    cmp "${TEST_DIR}/ipv6-before.yaml" "${CONFIG_FILE}"
)

replace_file() {
    return 1
}

if update_mode "${CONFIG_FILE}" "rule"; then
    echo "写入失败时 update_mode 不应返回成功" >&2
    exit 1
fi
cmp "${TEST_DIR}/before.yaml" "${CONFIG_FILE}"

echo "MODE 和 IPv6 测试通过"
