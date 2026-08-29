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

mv() {
    return 1
}

if update_mode "${CONFIG_FILE}" "rule"; then
    echo "写入失败时 update_mode 不应返回成功" >&2
    exit 1
fi
cmp "${TEST_DIR}/before.yaml" "${CONFIG_FILE}"

grep -q '^MODE=${MODE}$' "${REPO_DIR}/start.sh"

echo "MODE 测试通过"
