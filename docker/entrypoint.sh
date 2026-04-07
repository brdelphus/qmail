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
link_to_volume /home/vpopmail/domains /srv/mail/vpopmail/domains
link_to_volume /home/vpopmail/etc    /srv/mail/vpopmail/etc

# ── First-run: populate required control files from env vars ──────────────────
# Detected by absence of control/me — only runs once per fresh volume.

if [ ! -f "$CONTROL/me" ]; then
    if [ -z "$QMAIL_ME" ]; then
        echo "ERROR: QMAIL_ME is not set (must be the server's FQDN)" >&2
        exit 1
    fi

    QMAIL_DOMAIN=${QMAIL_DOMAIN:-$(echo "$QMAIL_ME" | cut -d. -f2-)}
    QMAIL_SOFTLIMIT=${QMAIL_SOFTLIMIT:-64000000}
    QMAIL_CONCURRENCY_INCOMING=${QMAIL_CONCURRENCY_INCOMING:-20}
    QMAIL_CONCURRENCY_REMOTE=${QMAIL_CONCURRENCY_REMOTE:-20}
    QMAIL_CONCURRENCY_LOCAL=${QMAIL_CONCURRENCY_LOCAL:-10}
    QMAIL_DATABYTES=${QMAIL_DATABYTES:-20000000}
    QMAIL_MAXRCPT=${QMAIL_MAXRCPT:-100}
    QMAIL_SPFBEHAVIOR=${QMAIL_SPFBEHAVIOR:-3}

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
    printf '%s' "2"                          > "$CONTROL/brtlimit"
    printf '%s' "HIGH:MEDIUM:!MD5:!RC4:!3DES:!LOW:!SSLv2:!SSLv3" \
                                             > "$CONTROL/tlsserverciphers"

    printf '%s' "MAILER-DAEMON"              > "$CONTROL/bouncefrom"
    printf '%s' "$QMAIL_ME"                  > "$CONTROL/bouncehost"
    printf '%s' "$QMAIL_SPFBEHAVIOR"         > "$CONTROL/spfbehavior"
    printf '%s' "272800"                     > "$CONTROL/queuelifetime"

    printf '|/var/qmail/bin/vdelivermail '"''"' delete\n' \
        > "$CONTROL/defaultdelivery"

    if [ ! -f "$CONTROL/tcp.smtp.cdb" ]; then
        printf '0.0.0.0:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"\n127.:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"\n:allow,CHKUSER_WRONGRCPTLIMIT="3"\n' \
            > "$CONTROL/tcp.smtp"
        /usr/bin/tcprules "$CONTROL/tcp.smtp.cdb" "$CONTROL/tcp.smtp.tmp" \
            < "$CONTROL/tcp.smtp"
    fi

    if [ ! -f "$CONTROL/tcp.submission.cdb" ]; then
        printf ':allow,CHKUSER_WRONGRCPTLIMIT="3"\n' > "$CONTROL/tcp.submission"
        /usr/bin/tcprules "$CONTROL/tcp.submission.cdb" "$CONTROL/tcp.submission.tmp" \
            < "$CONTROL/tcp.submission"
    fi

    if [ ! -f "$CONTROL/tcp.smtps.cdb" ]; then
        printf ':allow,CHKUSER_WRONGRCPTLIMIT="3"\n' > "$CONTROL/tcp.smtps"
        /usr/bin/tcprules "$CONTROL/tcp.smtps.cdb" "$CONTROL/tcp.smtps.tmp" \
            < "$CONTROL/tcp.smtps"
    fi

    # ── TLS certificate setup ──────────────────────────────────────────────────
    # Priority order:
    #   1. QMAIL_TLS_CERT + QMAIL_TLS_KEY env vars — paths to existing PEM files
    #      (e.g. Let's Encrypt). Combined into servercert.pem.
    #   2. servercert.pem already present in the volume — used as-is.
    #   3. Neither — self-signed cert generated for QMAIL_ME.
    #
    # Both qmail (sslserver) and Dovecot read the combined PEM from
    # $CONTROL/servercert.pem (certificate block first, then private key).
    # DH params are generated once at $CONTROL/dh4096.pem (2048-bit for speed;
    # raise to 4096 by setting QMAIL_DH_BITS=4096).

    if [ -n "$QMAIL_TLS_CERT" ] && [ -n "$QMAIL_TLS_KEY" ]; then
        if [ ! -f "$QMAIL_TLS_CERT" ]; then
            echo "ERROR: QMAIL_TLS_CERT=$QMAIL_TLS_CERT not found" >&2; exit 1
        fi
        if [ ! -f "$QMAIL_TLS_KEY" ]; then
            echo "ERROR: QMAIL_TLS_KEY=$QMAIL_TLS_KEY not found" >&2; exit 1
        fi
        echo "qmail: installing TLS cert from $QMAIL_TLS_CERT + $QMAIL_TLS_KEY"
        cat "$QMAIL_TLS_CERT" "$QMAIL_TLS_KEY" > "$CONTROL/servercert.pem"
        chmod 600 "$CONTROL/servercert.pem"
    elif [ ! -f "$CONTROL/servercert.pem" ]; then
        echo "qmail: generating self-signed TLS cert for $QMAIL_ME"
        openssl req -new -x509 -nodes -days 3650 \
            -subj "/CN=$QMAIL_ME" \
            -out "$CONTROL/servercert.pem" \
            -keyout "$CONTROL/servercert.pem" 2>/dev/null
        chmod 600 "$CONTROL/servercert.pem"
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
fi

# ── First-run: create primary vpopmail domain ────────────────────────────────
# Triggered by QMAIL_DOMAIN (already derived above from QMAIL_ME if not set).
# Skipped if the domain directory already exists in the volume.

if [ -n "$QMAIL_DOMAIN" ] && [ ! -d "/srv/mail/vpopmail/domains/$QMAIL_DOMAIN" ]; then
    echo "qmail: creating vpopmail domain $QMAIL_DOMAIN"
    /home/vpopmail/bin/vadddomain "$QMAIL_DOMAIN"
fi

# ── Hand off to runit ─────────────────────────────────────────────────────────
exec /usr/bin/runsvdir -P /etc/service
