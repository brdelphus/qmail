#!/bin/sh
set -e

QMAILDIR=/var/qmail
CONTROL=$QMAILDIR/control

# ── Volume layout ─────────────────────────────────────────────────────────────
# All mutable data lives under a single volume at /srv/mail.
# On first run we copy the image-baked defaults into the volume subdirs and
# replace the original paths with symlinks. On subsequent runs the symlinks
# already exist and we skip straight through.
#
#   /srv/mail/qmail/control    ← /var/qmail/control
#   /srv/mail/qmail/queue      ← /var/qmail/queue
#   /srv/mail/vpopmail/domains ← /home/vpopmail/domains
#   /srv/mail/vpopmail/etc     ← /home/vpopmail/etc

link_to_volume() {
    src="$1"   # path the application expects  (e.g. /var/qmail/control)
    dst="$2"   # path inside the volume        (e.g. /srv/mail/qmail/control)

    mkdir -p "$dst"

    if [ ! -L "$src" ]; then
        # First run: seed the volume with the image defaults if present
        if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
            cp -a "$src/." "$dst/"
        fi
        rm -rf "$src"
        ln -s "$dst" "$src"
    fi
}

link_to_volume /var/qmail/control    /srv/mail/qmail/control
link_to_volume /var/qmail/queue      /srv/mail/qmail/queue
link_to_volume /var/qmail/jgreylist  /srv/mail/jgreylist
link_to_volume /var/qmail/overlimit  /srv/mail/qmail/overlimit
link_to_volume /var/qmail/simscan    /srv/mail/qmail/simscan
link_to_volume /home/vpopmail/domains /srv/mail/vpopmail/domains
link_to_volume /home/vpopmail/etc    /srv/mail/vpopmail/etc

# ── MySQL backend setup (runs every startup) ──────────────────────────────────
# Writes /home/vpopmail/etc/vpopmail.mysql from env vars when MYSQL_HOST is set.
# Format: host|port|database|user|password  (read by vpopmail's MySQL auth module)
# Re-written on every startup so credential changes take effect without rebuilding.
if [ -n "$MYSQL_HOST" ]; then
    if [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASS" ] || [ -z "$MYSQL_DB" ]; then
        echo "ERROR: MYSQL_HOST is set but MYSQL_USER, MYSQL_PASS, or MYSQL_DB is missing" >&2
        exit 1
    fi
    MYSQL_PORT=${MYSQL_PORT:-3306}
    printf '%s|%s|%s|%s|%s\n' \
        "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_USER" "$MYSQL_PASS" "$MYSQL_DB" \
        > /home/vpopmail/etc/vpopmail.mysql
    chmod 600 /home/vpopmail/etc/vpopmail.mysql
    chown vpopmail:vchkpw /home/vpopmail/etc/vpopmail.mysql
    echo "qmail: vpopmail MySQL backend configured ($MYSQL_USER@$MYSQL_HOST:$MYSQL_PORT/$MYSQL_DB)"
fi

# ── qmail-spp greylisting plugin setup (runs every startup) ──────────────────
# Writes control/mysql.cnf and control/greylisting when GREYLIST_USER is set.
# control/greylisting is the plugin's config file (read by plugins/greylisting).
# control/jgreylist (0/1) is the separate toggle for the jgreylist binary wrapper.
if [ -n "$GREYLIST_USER" ]; then
    if [ -z "$GREYLIST_PASS" ] || [ -z "$GREYLIST_DB" ]; then
        echo "ERROR: GREYLIST_USER is set but GREYLIST_PASS or GREYLIST_DB is missing" >&2
        exit 1
    fi
    GREYLIST_HOST=${GREYLIST_HOST:-${MYSQL_HOST:-mariadb}}
    cat > "$CONTROL/mysql.cnf" << EOF
[client]
host=${GREYLIST_HOST}
user=${GREYLIST_USER}
password=${GREYLIST_PASS}
database=${GREYLIST_DB}
EOF
    chmod 600 "$CONTROL/mysql.cnf"
    chown vpopmail:vchkpw "$CONTROL/mysql.cnf"

    cat > "$CONTROL/greylisting" << EOF
mysql_default_file=control/mysql.cnf
block_expire=${GREYLIST_BLOCK_EXPIRE:-2}
record_expire=${GREYLIST_RECORD_EXPIRE:-2000}
record_expire_good=${GREYLIST_RECORD_EXPIRE_GOOD:-36}
loglevel=${GREYLIST_LOGLEVEL:-4}
EOF
    chmod 644 "$CONTROL/greylisting"
    chown root:root "$CONTROL/greylisting"

    # Default smtpplugins — written only on first run, editable afterwards.
    if [ ! -f "$CONTROL/smtpplugins" ]; then
        cat > "$CONTROL/smtpplugins" << 'EOF'
[rcpt]
plugins/ifauthskip
plugins/greylisting
EOF
        echo "qmail: spp greylisting configured ($GREYLIST_USER@$GREYLIST_HOST/$GREYLIST_DB)"
    fi
fi

# ── First-run: populate required control files from env vars ──────────────────
# Detected by absence of control/me — only runs once per fresh volume.

if [ ! -f "$CONTROL/me" ]; then
    if [ -z "$QMAIL_ME" ]; then
        echo "ERROR: QMAIL_ME is not set (must be the server's FQDN)" >&2
        exit 1
    fi

    QMAIL_DOMAIN=${QMAIL_DOMAIN:-$(echo "$QMAIL_ME" | cut -d. -f2-)}
    QMAIL_SOFTLIMIT=${QMAIL_SOFTLIMIT:-64000000}
    QMAIL_CONCURRENCY_INCOMING=${QMAIL_CONCURRENCY_INCOMING:-200}
    QMAIL_CONCURRENCY_REMOTE=${QMAIL_CONCURRENCY_REMOTE:-20}
    QMAIL_CONCURRENCY_LOCAL=${QMAIL_CONCURRENCY_LOCAL:-10}
    QMAIL_DATABYTES=${QMAIL_DATABYTES:-20000000}
    QMAIL_MAXRCPT=${QMAIL_MAXRCPT:-100}
    QMAIL_SPFBEHAVIOR=${QMAIL_SPFBEHAVIOR:-3}
    QMAIL_BOUNCEFROM=${QMAIL_BOUNCEFROM:-noreply}
    QMAIL_QUEUELIFETIME=${QMAIL_QUEUELIFETIME:-272800}
    QMAIL_BRTLIMIT=${QMAIL_BRTLIMIT:-2}
    QMAIL_TLS_CIPHERS=${QMAIL_TLS_CIPHERS:-HIGH:MEDIUM:!MD5:!RC4:!3DES:!LOW:!SSLv2:!SSLv3}

    echo "qmail: first run — writing control files for $QMAIL_ME"

    printf '%s' "$QMAIL_ME"                  > "$CONTROL/me"
    printf '%s' "$QMAIL_DOMAIN"              > "$CONTROL/defaultdomain"
    printf '%s' "$QMAIL_DOMAIN"              > "$CONTROL/defaulthost"
    printf '%s' "$QMAIL_DOMAIN"              > "$CONTROL/plusdomain"
    printf '%s' "$QMAIL_DOMAIN"              > "$CONTROL/rcpthosts"
    printf '%s' "$QMAIL_ME"                  > "$CONTROL/srs_domain"
    printf '%s' "$(openssl rand -hex 16)"    > "$CONTROL/srs_secrets"

    printf '%s' "$QMAIL_SOFTLIMIT"           > "$CONTROL/softlimit"
    printf '%s' "$QMAIL_CONCURRENCY_INCOMING" > "$CONTROL/concurrencyincoming"
    printf '%s' "$QMAIL_CONCURRENCY_REMOTE"  > "$CONTROL/concurrencyremote"
    printf '%s' "$QMAIL_CONCURRENCY_LOCAL"   > "$CONTROL/concurrencylocal"
    printf '%s' "$QMAIL_DATABYTES"           > "$CONTROL/databytes"
    printf '%s' "$QMAIL_MAXRCPT"             > "$CONTROL/maxrcpt"
    printf '%s' "$QMAIL_BRTLIMIT"             > "$CONTROL/brtlimit"
    printf '%s' "$QMAIL_TLS_CIPHERS"         > "$CONTROL/tlsserverciphers"

    printf '%s' "$QMAIL_BOUNCEFROM"          > "$CONTROL/bouncefrom"
    printf '%s' "$QMAIL_ME"                  > "$CONTROL/bouncehost"
    printf '%s' "$QMAIL_SPFBEHAVIOR"         > "$CONTROL/spfbehavior"
    printf '%s' "$QMAIL_QUEUELIFETIME"       > "$CONTROL/queuelifetime"

    # Optional: custom SPF explanation message
    if [ -n "$QMAIL_SPF_EXP" ]; then
        printf '%s' "$QMAIL_SPF_EXP" > "$CONTROL/spfexp"
    fi

    # Greetdelay and SURBL — configurable via env vars
    QMAIL_GREETDELAY=${QMAIL_GREETDELAY:-5}
    QMAIL_SURBL=${QMAIL_SURBL:-0}
    printf '%s' "$QMAIL_GREETDELAY"          > "$CONTROL/greetdelay"
    printf '%s' "$QMAIL_SURBL"               > "$CONTROL/surbl"

    # Deliver via LMTP to Dovecot container. Sieve filters run on delivery.
    # qmail-local sets $EXT (local part) and $HOST (domain) which the
    # lmtp-deliver script uses to construct the recipient address.
    printf '|/var/qmail/bin/lmtp-deliver\n' \
        > "$CONTROL/defaultdelivery"

    # Global Sieve script directories — drop .sieve files here for server-wide
    # rules (e.g. spam-to-Junk). Scripts run in alphabetical order.
    mkdir -p "$CONTROL/sieve/before.d" "$CONTROL/sieve/after.d"

    # QMAIL_RELAY_NETS — comma-separated list of IPs/prefixes that get RELAYCLIENT
    # on port 25 (e.g. "192.168.1.,10.0.0.2"). Loopback is always trusted.
    # QMAIL_CHKUSER_WRONGRCPTLIMIT — max invalid recipients before disconnect (default: 3)
    QMAIL_CHKUSER_WRONGRCPTLIMIT=${QMAIL_CHKUSER_WRONGRCPTLIMIT:-3}

    if [ ! -f "$CONTROL/tcp.smtp.cdb" ]; then
        {
            printf '0.0.0.0:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"\n'
            printf '127.:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"\n'
            [ "$QMAIL_DUALSTACK" = "1" ] && \
                printf '::1:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"\n'
            if [ -n "$QMAIL_RELAY_NETS" ]; then
                echo "$QMAIL_RELAY_NETS" | tr ',' '\n' | while IFS= read -r net; do
                    net=$(echo "$net" | tr -d ' ')
                    [ -n "$net" ] && printf '%s:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"\n' "$net"
                done
            fi
            printf ':allow,CHKUSER_WRONGRCPTLIMIT="%s"\n' "$QMAIL_CHKUSER_WRONGRCPTLIMIT"
        } > "$CONTROL/tcp.smtp"
        /usr/bin/tcprules "$CONTROL/tcp.smtp.cdb" "$CONTROL/tcp.smtp.tmp" \
            < "$CONTROL/tcp.smtp"
    fi

    if [ ! -f "$CONTROL/tcp.submission.cdb" ]; then
        printf ':allow,CHKUSER_WRONGRCPTLIMIT="%s"\n' "$QMAIL_CHKUSER_WRONGRCPTLIMIT" \
            > "$CONTROL/tcp.submission"
        /usr/bin/tcprules "$CONTROL/tcp.submission.cdb" "$CONTROL/tcp.submission.tmp" \
            < "$CONTROL/tcp.submission"
    fi

    if [ ! -f "$CONTROL/tcp.smtps.cdb" ]; then
        printf ':allow,CHKUSER_WRONGRCPTLIMIT="%s"\n' "$QMAIL_CHKUSER_WRONGRCPTLIMIT" \
            > "$CONTROL/tcp.smtps"
        /usr/bin/tcprules "$CONTROL/tcp.smtps.cdb" "$CONTROL/tcp.smtps.tmp" \
            < "$CONTROL/tcp.smtps"
    fi

    if [ ! -f "$CONTROL/dh4096.pem" ]; then
        echo "qmail: generating DH params (${QMAIL_DH_BITS:-2048}-bit) ..."
        openssl dhparam -out "$CONTROL/dh4096.pem" "${QMAIL_DH_BITS:-2048}" 2>/dev/null
    fi

    # ── Alias setup ───────────────────────────────────────────────────────────
    ALIASDIR="$QMAILDIR/alias"
    printf 'postmaster@%s\n' "$QMAIL_DOMAIN" > "$ALIASDIR/.qmail-postmaster"
    ln -sf .qmail-postmaster "$ALIASDIR/.qmail-mailer-daemon"
    ln -sf .qmail-postmaster "$ALIASDIR/.qmail-root"
    chmod 644 "$ALIASDIR/.qmail-postmaster"

    # ── DKIM setup ─────────────────────────────────────────────────────────────
    # Create domainkeys directory and generate key for primary domain.
    # filterargs enables DKIM signing via spawn-filter at qmail-remote level.
    mkdir -p "$CONTROL/domainkeys/$QMAIL_DOMAIN"
    chown -R qmailr:qmail "$CONTROL/domainkeys"
    chmod 700 "$CONTROL/domainkeys"

    if [ ! -f "$CONTROL/domainkeys/$QMAIL_DOMAIN/default" ]; then
        echo "qmail: generating DKIM key for $QMAIL_DOMAIN"
        /var/qmail/bin/dknewkey -d "$QMAIL_DOMAIN" -t rsa -b 2048 default \
            > "$CONTROL/domainkeys/$QMAIL_DOMAIN.dns.txt" 2>&1 || true
        chmod 600 "$CONTROL/domainkeys/$QMAIL_DOMAIN/default" 2>/dev/null || true
    fi

    # filterargs — DKIM signing configuration for outbound mail
    if [ ! -f "$CONTROL/filterargs" ]; then
        cat > "$CONTROL/filterargs" << 'EOF'
*:remote:/var/qmail/bin/qmail-dkim:DKIMQUEUE=/bin/cat,DKIMSIGN=/var/qmail/control/domainkeys/%/default,DKIMSIGNOPTIONS=-z 2
EOF
    fi

    # ── Dual-stack (IPv4 + IPv6) setup ────────────────────────────────────────
    # QMAIL_DUALSTACK=1 binds tcpserver on :: (accepts IPv4 + IPv6).
    # QMAIL_DUALSTACK=0 (default) binds on 0.0.0.0 (IPv4 only).
    # Requires Docker IPv6 to be enabled in the daemon config.
    QMAIL_DUALSTACK=${QMAIL_DUALSTACK:-0}
    printf '%s' "$QMAIL_DUALSTACK" > "$CONTROL/dualstack"

    # ── Rate limiting setup ───────────────────────────────────────────────────
    # control/relaylimits — per-user/domain/IP send limits for rcptcheck-overlimit.
    # Format: "user@domain:N", "domain:N", "IP:N", ":N" (catch-all default). 0=unlimited.
    chmod 755 "$QMAILDIR/overlimit"
    chown vpopmail:vchkpw "$QMAILDIR/overlimit"
    if [ ! -f "$CONTROL/relaylimits" ]; then
        QMAIL_RELAY_LIMIT=${QMAIL_RELAY_LIMIT:-1000}
        cat > "$CONTROL/relaylimits" << EOF
# Per-user/domain/IP send limits for rcptcheck-overlimit.
# Format: user@domain:N  |  domain:N  |  IP:N  |  :N (default)
# 0 = unlimited for that entry. Reset daily by cron.
# Examples:
#   poweruser@example.com:5000
#   example.com:2000
#   1.2.3.4:0
:${QMAIL_RELAY_LIMIT}
EOF
        echo "qmail: relay rate limit set to ${QMAIL_RELAY_LIMIT} messages/period"
    fi

    # ── Optional: jgreylist setup ─────────────────────────────────────────────
    # QMAIL_GREYLISTING=1 enables the jgreylist binary wrapper on port 25.
    # State files live in /var/qmail/jgreylist (persisted in the volume).
    # Run jgreylist-clean periodically to purge expired entries.
    QMAIL_GREYLISTING=${QMAIL_GREYLISTING:-0}
    printf '%s' "$QMAIL_GREYLISTING" > "$CONTROL/jgreylist"
    chmod 0700 "$QMAILDIR/jgreylist"
    chown vpopmail:vchkpw "$QMAILDIR/jgreylist"

    # ── Optional: qmail-taps-extended setup ───────────────────────────────────
    # QMAIL_TAPS — semicolon-separated tap rules, each in the format:
    #   TYPE:REGEX:DESTINATION
    #   TYPE: F (from), T (to), A (all/catch-all)
    #   e.g. "F:.*@example.com:archive@example.com;T:.*@example.com:audit@other.com"
    # The taps file is plain text — edit it directly on a live container and
    # qmail picks up changes without a restart.
    if [ ! -f "$CONTROL/taps" ]; then
        if [ -n "$QMAIL_TAPS" ]; then
            echo "$QMAIL_TAPS" | tr ';' '\n' > "$CONTROL/taps"
            echo "qmail: taps configured"
        else
            # Empty file — tapping disabled until rules are added manually
            touch "$CONTROL/taps"
        fi
    fi

    # ── Optional: DNSBL/RBL setup ──────────────────────────────────────────────
    # Create default dnsbllist if not present. Edit to customize blocklists.
    if [ ! -f "$CONTROL/dnsbllist" ]; then
        cat > "$CONTROL/dnsbllist" << 'EOF'
# DNS blocklists — one per line. Prefix with - for 553 reject (vs 451 defer).
# See: https://www.sagredo.eu/en/qmail-notes-185/realtime-block-list-rbl-qmail-dnsbl-162.html
#-zen.spamhaus.org
#-b.barracudacentral.org
#-bl.spamcop.net
EOF
    fi

    # ── vqadmin HTTP auth setup ────────────────────────────────────────────────
    # vqadmin is a system-level admin tool — requires HTTP basic auth.
    # Set VQADMIN_PASS env var to configure password, or generate random one.
    if [ ! -f "$CONTROL/vqadmin.htpasswd" ]; then
        VQADMIN_USER=${VQADMIN_USER:-admin}
        if [ -z "$VQADMIN_PASS" ]; then
            VQADMIN_PASS=$(openssl rand -base64 12)
            echo "qmail: vqadmin password (user: $VQADMIN_USER): $VQADMIN_PASS"
        fi
        htpasswd -bc "$CONTROL/vqadmin.htpasswd" "$VQADMIN_USER" "$VQADMIN_PASS"
        chmod 640 "$CONTROL/vqadmin.htpasswd"
        chown vpopmail:vchkpw "$CONTROL/vqadmin.htpasswd"
    fi
fi

# ── First-run: create primary vpopmail domain ────────────────────────────────
# Triggered by QMAIL_DOMAIN (already derived above from QMAIL_ME if not set).
# Skipped if the domain directory already exists in the volume.

if [ -n "$QMAIL_DOMAIN" ] && [ ! -d "/srv/mail/vpopmail/domains/$QMAIL_DOMAIN" ]; then
    echo "qmail: creating vpopmail domain $QMAIL_DOMAIN"
    _postmaster_pass="$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    /home/vpopmail/bin/vadddomain "$QMAIL_DOMAIN" "$_postmaster_pass"
    echo "qmail: postmaster@$QMAIL_DOMAIN created (change password with vpasswd)"
    # vadddomain writes a vdelivermail .qmail-default — replace with LMTP
    # delivery to Dovecot so Sieve filters run on every delivery.
    printf '|/var/qmail/bin/lmtp-deliver\n' \
        > "/home/vpopmail/domains/$QMAIL_DOMAIN/.qmail-default"
    chown vpopmail:vchkpw "/home/vpopmail/domains/$QMAIL_DOMAIN/.qmail-default"
fi

# ── TLS certificate setup (runs every startup) ───────────────────────────────
# Priority order:
#   1. QMAIL_TLS_CERT + QMAIL_TLS_KEY env vars — paths to existing PEM files
#      (e.g. Let's Encrypt). Combined into servercert.pem on every startup so
#      renewed certs are picked up automatically after a container restart.
#   2. servercert.pem already present in the volume — used as-is.
#   3. Neither — self-signed cert generated for QMAIL_ME (first run only).
#
# Both qmail (sslserver) and Dovecot read the combined PEM from
# $CONTROL/servercert.pem (certificate block first, then private key).
# DH params are generated once at $CONTROL/dh4096.pem (2048-bit for speed;
# raise to 4096 by setting QMAIL_DH_BITS=4096).

if [ -n "$QMAIL_TLS_CERT_B64" ] && [ -n "$QMAIL_TLS_KEY_B64" ]; then
    echo "qmail: installing TLS cert from QMAIL_TLS_CERT_B64 + QMAIL_TLS_KEY_B64"
    { printf '%s' "$QMAIL_TLS_CERT_B64" | base64 -d
      printf '%s' "$QMAIL_TLS_KEY_B64"  | base64 -d
    } > "$CONTROL/servercert.pem"
    chmod 600 "$CONTROL/servercert.pem"
elif [ -n "$QMAIL_TLS_CERT" ] && [ -n "$QMAIL_TLS_KEY" ]; then
    if [ ! -f "$QMAIL_TLS_CERT" ] || [ ! -f "$QMAIL_TLS_KEY" ]; then
        echo "qmail: WARNING: TLS cert not found at $QMAIL_TLS_CERT — falling back to self-signed" >&2
        # Fall through: cert will be generated below if servercert.pem is absent,
        # or an existing one will be reused. Run certbot then restart qmail.
    else
        echo "qmail: installing TLS cert from $QMAIL_TLS_CERT + $QMAIL_TLS_KEY"
        cat "$QMAIL_TLS_CERT" "$QMAIL_TLS_KEY" > "$CONTROL/servercert.pem"
        chmod 600 "$CONTROL/servercert.pem"
    fi
fi
if [ ! -f "$CONTROL/servercert.pem" ]; then
    _me=${QMAIL_ME:-$(cat "$CONTROL/me" 2>/dev/null)}
    echo "qmail: generating self-signed TLS cert for $_me"
    openssl req -new -x509 -nodes -days 3650 \
        -subj "/CN=$_me" \
        -out "$CONTROL/servercert.pem" \
        -keyout "$CONTROL/servercert.pem" 2>/dev/null
    chmod 600 "$CONTROL/servercert.pem"
    unset _me
fi

# ── SNI certificate setup (runs every startup) ────────────────────────────────
# QMAIL_SNI_CERTS — semicolon-separated triplets: domain:cert_path:key_path
# Supports multiple domains beyond the primary (e.g. additional hosted domains).
# Re-runs on every startup so renewed Let's Encrypt certs are picked up without
# rebuilding.
#
# Example:
#   QMAIL_SNI_CERTS: "mail2.example.org:/etc/letsencrypt/live/mail2.example.org/fullchain.pem:/etc/letsencrypt/live/mail2.example.org/privkey.pem"
#
# For qmail: combines cert+key into control/servercerts/<domain>/servercert.pem
# For Dovecot: writes local_name blocks to control/dovecot-sni.conf (included automatically)
if [ -n "$QMAIL_SNI_CERTS" ]; then
    : > "$CONTROL/dovecot-sni.conf"
    echo "$QMAIL_SNI_CERTS" | tr ';' '\n' | while IFS= read -r triplet; do
        domain=$(echo "$triplet" | cut -d: -f1 | tr -d ' ')
        cert=$(echo "$triplet"   | cut -d: -f2 | tr -d ' ')
        key=$(echo "$triplet"    | cut -d: -f3 | tr -d ' ')
        [ -z "$domain" ] || [ -z "$cert" ] || [ -z "$key" ] && continue
        if [ ! -f "$cert" ]; then
            echo "qmail: WARNING: SNI cert not found for $domain: $cert" >&2; continue
        fi
        if [ ! -f "$key" ]; then
            echo "qmail: WARNING: SNI key not found for $domain: $key" >&2; continue
        fi
        echo "qmail: installing SNI cert for $domain"
        mkdir -p "$CONTROL/servercerts/$domain"
        cat "$cert" "$key" > "$CONTROL/servercerts/$domain/servercert.pem"
        chmod 600 "$CONTROL/servercerts/$domain/servercert.pem"
        cat >> "$CONTROL/dovecot-sni.conf" <<EOF
local_name $domain {
  ssl_cert = <$cert
  ssl_key  = <$key
}
EOF
    done
fi

# ── simscan setup (runs every startup) ───────────────────────────────────────
# /var/qmail/simscan is volume-linked above; owned by clamav so simscan can
# write its working files. simcontrol is written on first run and compiled
# into simcontrol.cdb on every startup (simscanmk is fast).
chown clamav:clamav /srv/mail/qmail/simscan 2>/dev/null || true
if [ ! -f "$QMAILDIR/simscan/simcontrol" ]; then
    SIMSCAN_CLAM=${SIMSCAN_CLAM:-yes}
    SIMSCAN_SPAM=${SIMSCAN_SPAM:-yes}
    SIMSCAN_SPAM_HITS=${SIMSCAN_SPAM_HITS:-9.0}
    SIMSCAN_SIZE_LIMIT=${SIMSCAN_SIZE_LIMIT:-20000000}
    SIMSCAN_DEBUG=${SIMSCAN_DEBUG:-0}

    # Build the catch-all simcontrol rule from env vars
    RULE="clam=${SIMSCAN_CLAM},spam=${SIMSCAN_SPAM},spam_hits=${SIMSCAN_SPAM_HITS},size_limit=${SIMSCAN_SIZE_LIMIT}"
    # Blocked attachment extensions: semicolon-separated list → colon-separated for simcontrol
    # e.g. SIMSCAN_ATTACH=".vbs;.lnk;.scr" → attach=.vbs:.lnk:.scr
    if [ -n "$SIMSCAN_ATTACH" ]; then
        ATTACH_LIST=$(printf '%s' "$SIMSCAN_ATTACH" | tr ';' ':')
        RULE="${RULE},attach=${ATTACH_LIST}"
    fi

    cat > "$QMAILDIR/simscan/simcontrol" << EOF
# simscan per-domain control — compiled by simscanmk into simcontrol.cdb.
# Format: [user@]domain:option=value,...  (empty LHS = catch-all default)
# Examples:
#   user@example.com:clam=yes,spam=yes,spam_hits=9.0,attach=.vbs:.lnk:.scr
#   example.com:clam=yes,spam=yes,spam_hits=7.0
:${RULE}
EOF
    echo "qmail: simscan simcontrol written (clam=${SIMSCAN_CLAM} spam=${SIMSCAN_SPAM} spam_hits=${SIMSCAN_SPAM_HITS} size_limit=${SIMSCAN_SIZE_LIMIT})"
fi
/var/qmail/bin/simscanmk 2>/dev/null && echo "qmail: simscanmk compiled" || true
chown -R clamav:clamav "$QMAILDIR/simscan" 2>/dev/null || true

# ── Service toggles ───────────────────────────────────────────────────────────
# Enable/disable services based on environment variables.
# Disabled services have their symlink removed from /etc/service.
QMAIL_SMTP=${QMAIL_SMTP:-true}
QMAIL_SMTPS=${QMAIL_SMTPS:-true}
QMAIL_SUBMISSION=${QMAIL_SUBMISSION:-true}
QMAIL_HTTP=${QMAIL_HTTP:-true}

echo "qmail: services enabled:"

if [ "$QMAIL_SMTP" = "true" ]; then
    echo "  - SMTP (25)"
else
    rm -f /etc/service/qmail-smtpd
    echo "  - SMTP (25) [DISABLED]"
fi

if [ "$QMAIL_SMTPS" = "true" ]; then
    echo "  - SMTPS (465)"
else
    rm -f /etc/service/qmail-smtps
    echo "  - SMTPS (465) [DISABLED]"
fi

if [ "$QMAIL_SUBMISSION" = "true" ]; then
    echo "  - Submission (587)"
else
    rm -f /etc/service/qmail-submission
    echo "  - Submission (587) [DISABLED]"
fi

if [ "$QMAIL_HTTP" = "true" ]; then
    echo "  - HTTP (80)"
else
    rm -f /etc/service/lighttpd
    echo "  - HTTP (80) [DISABLED]"
fi

# qmail-send and vusaged always run (core services)
echo "  - qmail-send (queue processor)"
echo "  - vusaged (quota daemon)"

# ── Hand off to runit ─────────────────────────────────────────────────────────
exec /usr/bin/runsvdir -P /etc/service
