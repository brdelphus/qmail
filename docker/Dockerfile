# ── Stage 1: builder ─────────────────────────────────────────────────────────
# The compilation chain is strictly ordered:
#   libsrs2  →  netqmail (vanilla)  →  vpopmail  →  patched qmail
#
# Why that order:
#  • netqmail must be installed first so that /var/qmail exists with the
#    correct layout and ownership before vpopmail's configure runs.
#  • vpopmail must be installed before the patched qmail because chkuser.c
#    includes vpopmail.h / vauth.h / vpopmail_config.h, and qmail-smtpd links
#    against the library list written to /home/vpopmail/etc/lib_deps.
#  • libsrs2 can be built any time before the patched qmail; doing it first
#    keeps the steps clean.
FROM debian:bookworm-slim AS builder

# All client dev libraries are installed so the image can be rebuilt for any
# vpopmail auth backend without changing the Dockerfile.
# Select the backend at build time with: --build-arg VPOPMAIL_AUTH=<module>
#   mysql   → libmariadb-dev-compat (MariaDB replaces MySQL in Debian)
#   pgsql   → libpq-dev
#   ldap    → libldap-dev
#   cdb     → no extra library
#   passwd  → no extra library
ARG VPOPMAIL_AUTH=cdb

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential wget ca-certificates \
        libssl-dev libidn2-dev \
        libbz2-dev liblz4-dev \
        libmariadb-dev-compat \
        libpq-dev \
        libldap-dev \
        groff \
    && rm -rf /var/lib/apt/lists/*

# Users/groups must exist before `make setup` in any of the qmail build steps.
# UIDs/GIDs are pinned so the runtime stage can reuse them without chown passes.
RUN groupadd -g 2107 qmail \
 && groupadd -g 2108 nofiles \
 && groupadd -g 2109 vchkpw \
 && useradd -u 2107 -g nofiles -d /var/qmail/alias -M -s /usr/sbin/nologin alias \
 && useradd -u 2108 -g nofiles -d /var/qmail       -M -s /usr/sbin/nologin qmaild \
 && useradd -u 2109 -g nofiles -d /var/qmail       -M -s /usr/sbin/nologin qmaill \
 && useradd -u 2110 -g qmail   -d /var/qmail       -M -s /usr/sbin/nologin qmailp \
 && useradd -u 2111 -g nofiles -d /var/qmail       -M -s /usr/sbin/nologin qmailq \
 && useradd -u 2112 -g qmail   -d /var/qmail       -M -s /usr/sbin/nologin qmailr \
 && useradd -u 2113 -g qmail   -d /var/qmail       -M -s /usr/sbin/nologin qmails \
 && useradd -u 89   -g vchkpw  -d /home/vpopmail   -m -s /usr/sbin/nologin vpopmail

WORKDIR /build

# ── Step 1: libsrs2 ──────────────────────────────────────────────────────────
# conf-ld already carries -L/usr/local/lib, so installing here is enough.
RUN wget -q https://www.sagredo.eu/files/qmail/tar/libsrs2-1.0.18.tar.gz \
 && tar xzf libsrs2-1.0.18.tar.gz \
 && cd libsrs2-1.0.18 \
 && ./configure --prefix=/usr/local \
 && make \
 && make install

# ── Step 1b: ucspi-ssl ───────────────────────────────────────────────────────
# Not in Debian's repos; build from Erwin Hoffmann's fork (OpenSSL 3.x
# compatible). package/install compiles but doesn't install anywhere
# (command-cp is empty), so we copy sslserver/sslclient to /usr/local/bin
# ourselves. The runtime stage picks them up via COPY --from=builder.
# Notes:
#  • sed patches print-cc.sh to add -fcommon (gcc 10+ changed the default to
#    -fno-common, causing multiple-definition errors on global strnum).
#  • "- sslperl" suppresses the sslperl target which requires libperl-dev.
RUN wget -q https://www.fehcom.de/ipnet/ucspi-ssl/ucspi-ssl-0.99e.tgz \
 && tar xzf ucspi-ssl-0.99e.tgz \
 && cd host/superscript.com/net/ucspi-ssl-0.99e \
 && sed -i 's/^ccbase="cc /ccbase="cc -fcommon /' src/print-cc.sh \
 && package/install - sslperl \
 && cp compile/sslserver compile/sslclient /usr/local/bin/

# ── Step 2: netqmail (vanilla) ───────────────────────────────────────────────
# vpopmail's configure expects /var/qmail to exist with the correct layout and
# ownership. The patched qmail overwrites these binaries in step 4; the
# directory structure is all we need from this step.
RUN wget -q https://www.sagredo.eu/files/qmail/tar/netqmail-1.06.tar.gz \
 && tar xzf netqmail-1.06.tar.gz \
 && cd netqmail-1.06 \
 && make it \
 && make setup

# ── Step 3: vpopmail ─────────────────────────────────────────────────────────
# Now that /var/qmail exists, vpopmail's configure finds what it needs.
# After `make install-strip`:
#   /home/vpopmail/include/  — vpopmail.h, vauth.h, vpopmail_config.h
#   /home/vpopmail/etc/lib_deps — library flags consumed by the patched qmail
#
# Auth backend is selected via VPOPMAIL_AUTH build arg (default: cdb).
# Rebuild with --build-arg VPOPMAIL_AUTH=pgsql|ldap|mysql|passwd as needed.
ARG VPOPMAIL_VERSION=5.6.13
RUN wget -q https://github.com/sagredo-dev/vpopmail/archive/refs/tags/v${VPOPMAIL_VERSION}.tar.gz \
 && tar xzf v${VPOPMAIL_VERSION}.tar.gz \
 && cd vpopmail-${VPOPMAIL_VERSION} \
 && ./configure \
        --enable-vpopuser=vpopmail \
        --enable-vpopgroup=vchkpw \
        --enable-auth-module="${VPOPMAIL_AUTH}" \
        --enable-file-locking=flock \
        --enable-auth-logging \
 && make -j"$(nproc)" \
 && make install-strip

# ── Step 3b: autorespond ─────────────────────────────────────────────────────
# Vacation/out-of-office responder required by qmailadmin.
# v2.0.9 fixes a segfault in To: header processing.
RUN wget -q https://github.com/sagredo-dev/autorespond/archive/refs/tags/v2.0.9.tar.gz \
 && tar xzf v2.0.9.tar.gz \
 && cd autorespond-2.0.9 \
 && chown -R root:root . \
 && make \
 && make install

# ── Step 4: patched qmail ────────────────────────────────────────────────────
# chkuser.c can now resolve its includes from /home/vpopmail/include, and the
# qmail-smtpd link step reads /home/vpopmail/etc/lib_deps for the vpopmail
# library flags. `make setup` overwrites the vanilla netqmail binaries from
# step 2, leaving /var/qmail in its final state.
COPY . /usr/src/qmail/
WORKDIR /usr/src/qmail
RUN make it && make setup

# ── Step 5: ezmlm-idx ────────────────────────────────────────────────────────
# High-speed mailing list manager for qmail.
# Requires lang/default symlink before building.
WORKDIR /build
RUN wget -q https://untroubled.org/ezmlm/archive/7.2.2/ezmlm-idx-7.2.2.tar.gz \
 && tar xzf ezmlm-idx-7.2.2.tar.gz \
 && cd ezmlm-idx-7.2.2 \
 && ln -s en_US lang/default \
 && make \
 && make man \
 && make install

# ── Step 6: qmailadmin ───────────────────────────────────────────────────────
# Web-based admin interface for vpopmail domains/users.
# Installs to /var/www/qmailadmin (CGI binary + HTML templates).
ARG QMA_VERSION=1.2.27
RUN wget -q https://github.com/sagredo-dev/qmailadmin/archive/refs/tags/v${QMA_VERSION}.tar.gz \
 && tar xzf v${QMA_VERSION}.tar.gz \
 && cd qmailadmin-${QMA_VERSION} \
 && chown -R root:root . \
 && ./configure \
        --enable-htmldir=/var/www/qmailadmin \
        --enable-cgibindir=/var/www/qmailadmin/cgi-bin \
        --enable-cgipath=/cgi-bin/qmailadmin \
        --enable-imagedir=/var/www/qmailadmin/images \
        --enable-imageurl=/images \
        --enable-htmllibdir=/var/www/qmailadmin/html \
        --enable-qmaildir=/var/qmail \
        --enable-domain-autofill \
        --enable-vpopuser=vpopmail \
        --enable-vpopgroup=vchkpw \
        --enable-autoresponder-path=/usr/local/bin \
        --enable-ezmlmdir=/usr/local/bin/ezmlm \
        --enable-modify-quota \
        --enable-maxusersperpage=50 \
        --enable-maxaliasesperpage=50 \
        --disable-ezmlm-mysql \
        --disable-trivial-password \
 && make \
 && make install-strip


# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim

ARG VPOPMAIL_AUTH=cdb

# Runtime client libraries — only the one matching the compiled-in backend
# is strictly needed, but installing all keeps the image backend-agnostic so
# you can swap the backend by rebuilding without touching this stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
        runit \
        ucspi-tcp \
        openssl \
        libssl3 \
        libidn2-0 \
        libbz2-1.0 liblz4-1 \
        libmariadb3 \
        libpq5 \
        libldap-2.5-0 \
        dovecot-imapd \
        lighttpd \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Same pinned UIDs/GIDs as builder — no ownership fix-up needed
RUN groupadd -g 2107 qmail \
 && groupadd -g 2108 nofiles \
 && groupadd -g 2109 vchkpw \
 && useradd -u 2107 -g nofiles -d /var/qmail/alias -M -s /usr/sbin/nologin alias \
 && useradd -u 2108 -g nofiles -d /var/qmail       -M -s /usr/sbin/nologin qmaild \
 && useradd -u 2109 -g nofiles -d /var/qmail       -M -s /usr/sbin/nologin qmaill \
 && useradd -u 2110 -g qmail   -d /var/qmail       -M -s /usr/sbin/nologin qmailp \
 && useradd -u 2111 -g nofiles -d /var/qmail       -M -s /usr/sbin/nologin qmailq \
 && useradd -u 2112 -g qmail   -d /var/qmail       -M -s /usr/sbin/nologin qmailr \
 && useradd -u 2113 -g qmail   -d /var/qmail       -M -s /usr/sbin/nologin qmails \
 && useradd -u 89   -g vchkpw  -d /home/vpopmail   -m -s /usr/sbin/nologin vpopmail

COPY --from=builder /var/qmail        /var/qmail
COPY --from=builder /home/vpopmail    /home/vpopmail
COPY --from=builder /usr/local/lib    /usr/local/lib
COPY --from=builder /usr/local/bin    /usr/local/bin
COPY --from=builder /var/www/qmailadmin /var/www/qmailadmin

RUN echo '/usr/local/lib' > /etc/ld.so.conf.d/usr-local.conf \
 && ldconfig \
 && ln -s /var/qmail/bin/sendmail /usr/sbin/sendmail

# Dovecot config — overrides the Debian default
COPY docker/dovecot.conf /etc/dovecot/dovecot.conf

# Lighttpd config for qmailadmin CGI
COPY docker/lighttpd.conf /etc/lighttpd/lighttpd.conf

# Runit service definitions
COPY docker/runit /etc/sv
RUN mkdir -p /etc/service /var/log/qmail \
 && for svc in qmail-smtpd qmail-send qmail-submission qmail-smtps dovecot lighttpd; do \
      chmod +x /etc/sv/$svc/run /etc/sv/$svc/log/run; \
      mkdir -p /var/log/qmail/$svc; \
      ln -s /etc/sv/$svc /etc/service/$svc; \
    done \
 && chown -R qmaill:nofiles /var/log/qmail \
 && mkdir -p /run/dovecot

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Label the compiled-in vpopmail backend for introspection
LABEL vpopmail.auth="${VPOPMAIL_AUTH}"

EXPOSE 25 80 110 143 465 587 993 995

# Single persistent volume — all mutable data lives under /srv/mail:
#   /srv/mail/qmail/control     → symlinked from /var/qmail/control
#   /srv/mail/qmail/queue       → symlinked from /var/qmail/queue
#   /srv/mail/vpopmail/domains  → symlinked from /home/vpopmail/domains
#   /srv/mail/vpopmail/etc      → symlinked from /home/vpopmail/etc
# The entrypoint creates the subdirs and symlinks on first run.
VOLUME ["/srv/mail"]

ENTRYPOINT ["/entrypoint.sh"]
