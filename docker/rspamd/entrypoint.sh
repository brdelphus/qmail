#!/bin/sh
set -e

# Rspamd entrypoint — configures controller password and module layer toggles.
# Writes to override.d (takes precedence over local.d per rspamd config hierarchy).

mkdir -p /etc/rspamd/override.d

# ── Controller password ───────────────────────────────────────────────────────
if [ -n "$RSPAMD_PASSWORD" ]; then
    HASH=$(rspamadm pw -p "$RSPAMD_PASSWORD" 2>/dev/null)
    cat > /etc/rspamd/override.d/worker-controller.inc << EOF
# Generated at container start from RSPAMD_PASSWORD env var — do not edit manually.
password = "${HASH}";
EOF
    echo "rspamd: controller password configured"
else
    echo "rspamd: WARNING — RSPAMD_PASSWORD not set; controller is unauthenticated"
fi

# ── Feature layer toggles ─────────────────────────────────────────────────────
# When *_LAYER=qmail: write enabled=false into override.d to disable the rspamd module.
# When *_LAYER=rspamd (default): remove any override disable file so the module runs.
# Must match the *_LAYER values set in the qmail service (both read from the same .env).

# SPF
SPF_LAYER=${SPF_LAYER:-rspamd}
if [ "$SPF_LAYER" = "qmail" ]; then
    printf 'enabled = false;\n' > /etc/rspamd/override.d/spf.conf
    echo "rspamd: SPF module disabled (layer=qmail)"
else
    rm -f /etc/rspamd/override.d/spf.conf
    echo "rspamd: SPF module enabled (layer=rspamd)"
fi

# DKIM verification (note: dkim_signing stays disabled via local.d/dkim_signing.conf)
DKIM_VERIFY_LAYER=${DKIM_VERIFY_LAYER:-rspamd}
if [ "$DKIM_VERIFY_LAYER" = "qmail" ]; then
    printf 'enabled = false;\n' > /etc/rspamd/override.d/dkim.conf
    echo "rspamd: DKIM verify module disabled (layer=qmail)"
else
    rm -f /etc/rspamd/override.d/dkim.conf
    echo "rspamd: DKIM verify module enabled (layer=rspamd)"
fi

# DNSBL/RBL
DNSBL_LAYER=${DNSBL_LAYER:-rspamd}
if [ "$DNSBL_LAYER" = "qmail" ]; then
    printf 'enabled = false;\n' > /etc/rspamd/override.d/rbl.conf
    echo "rspamd: RBL module disabled (layer=qmail)"
else
    rm -f /etc/rspamd/override.d/rbl.conf
    echo "rspamd: RBL module enabled (layer=rspamd)"
fi

# SURBL/URI blocklists
SURBL_LAYER=${SURBL_LAYER:-rspamd}
if [ "$SURBL_LAYER" = "qmail" ]; then
    printf 'enabled = false;\n' > /etc/rspamd/override.d/surbl.conf
    echo "rspamd: SURBL module disabled (layer=qmail)"
else
    rm -f /etc/rspamd/override.d/surbl.conf
    echo "rspamd: SURBL module enabled (layer=rspamd)"
fi

exec "$@"
