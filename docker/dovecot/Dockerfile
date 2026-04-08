# Dovecot container — IMAP/POP3/ManageSieve/LMTP with SQL auth
# Separate from qmail; authenticates directly against MariaDB vpopmail schema.
FROM debian:bookworm-slim

# Pin Dovecot to 2.3.x — Dovecot 2.4 changed some configuration options
RUN printf 'Package: dovecot-*\nPin: version 1:2.3.*\nPin-Priority: 1001\n' \
        > /etc/apt/preferences.d/dovecot-23

RUN apt-get update && apt-get install -y --no-install-recommends \
        dovecot-imapd \
        dovecot-pop3d \
        dovecot-lmtpd \
        dovecot-sieve \
        dovecot-managesieved \
        dovecot-mysql \
        openssl \
        libmariadb3 \
        netcat-openbsd \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create vpopmail user/group with same UID/GID as qmail container.
# Dovecot runs mail processes as vpopmail to access Maildirs.
RUN groupadd -g 2109 vchkpw \
 && useradd -u 89 -g vchkpw -d /home/vpopmail -m -s /usr/sbin/nologin vpopmail

# Create directories for mail and config
RUN mkdir -p /srv/mail/vpopmail/domains \
             /srv/qmail/control \
             /run/dovecot \
 && chown -R vpopmail:vchkpw /srv/mail/vpopmail

# Copy configuration files
COPY docker/dovecot/dovecot.conf /etc/dovecot/dovecot.conf
COPY docker/dovecot/dovecot-sql.conf.ext /etc/dovecot/dovecot-sql.conf.ext
COPY docker/dovecot/entrypoint.sh /entrypoint.sh
COPY docker/dovecot/healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh \
 && chmod 600 /etc/dovecot/dovecot-sql.conf.ext

# Ports:
#   110  - POP3
#   143  - IMAP
#   993  - IMAPS
#   995  - POP3S
#   4190 - ManageSieve
#   24   - LMTP (for qmail delivery)
EXPOSE 110 143 993 995 4190 24

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD /healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
