#!/bin/sh
set -e

# Rspamd entrypoint — generates controller password from RSPAMD_PASSWORD env var.
# Writes to override.d so it takes precedence over any local.d stub.

if [ -n "$RSPAMD_PASSWORD" ]; then
    HASH=$(rspamadm pw -p "$RSPAMD_PASSWORD" 2>/dev/null)
    mkdir -p /etc/rspamd/override.d
    cat > /etc/rspamd/override.d/worker-controller.inc << EOF
# Generated at container start from RSPAMD_PASSWORD env var — do not edit manually.
password = "${HASH}";
EOF
    echo "rspamd: controller password configured"
else
    echo "rspamd: WARNING — RSPAMD_PASSWORD not set; controller is unauthenticated"
fi

exec "$@"
