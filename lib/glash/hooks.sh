#!/bin/bash

run_post_subscription_hooks() {
    local config_file="$1"
    local script
    local hook_count=0
    local had_nullglob=0
    local had_dotglob=0
    local -a scripts

    [ -d "${HOOK_DIR}" ] || return 0
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    scripts=("${HOOK_DIR}"/*)
    [ "${had_nullglob}" -eq 1 ] || shopt -u nullglob
    [ "${had_dotglob}" -eq 1 ] || shopt -u dotglob

    for script in "${scripts[@]}"; do
        [ -f "${script}" ] && [ -x "${script}" ] || continue
        hook_count=$((hook_count + 1))
        log_info "🔧 执行 hook: $(basename "${script}")"
        if ! "${script}" "${config_file}"; then
            log_error "❌ Hook $(basename "${script}") 执行失败"
            return 1
        fi
    done

    log_info "✅ 已执行 ${hook_count} 个配置 hook"
}
