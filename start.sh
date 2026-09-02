#!/bin/bash

# Thin entrypoint. Runtime code lives in lib/glash so every responsibility can
# be sourced and tested independently.
GLASH_APP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for module in \
    common.sh \
    environment.sh \
    config.sh \
    hooks.sh \
    mihomo.sh \
    subscription.sh \
    cron.sh \
    app.sh; do
    # shellcheck source=/dev/null
    source "${GLASH_APP_DIR}/lib/glash/${module}"
done

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

main "$@"
