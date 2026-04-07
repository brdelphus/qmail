# Docker TODO

## Multi-container architecture

The current setup runs everything in a single container. The following services
should be split into separate containers and wired together via Docker Compose.

---

### MySQL (vpopmail auth backend)

Currently vpopmail uses CDB (file-based). For larger deployments, switch to MySQL:

- Spin up a separate `mysql` (or `mariadb`) container
- Rebuild the qmail image with `--build-arg VPOPMAIL_AUTH=mysql`
- Pass DB credentials via env vars (`MYSQL_HOST`, `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_DB`)
- Write `vpopmail/etc/vpopmail.mysql` from those vars in the entrypoint
- The qmailadmin and vqadmin CGIs will pick up the MySQL backend automatically
- Consider a dedicated volume for MySQL data

---

### ClamAV (antivirus)

[ClamAV](https://www.clamav.net) scans inbound mail for viruses:

- Run `clamav/clamav` in its own container (`clamd` + `freshclam`)
- `clamd` listens on TCP port 3310 inside the clamav container
- `freshclam` keeps virus definitions updated automatically
- No shared Unix socket needed — connection is over TCP between containers

---

### Rspamd (spam filtering)

[Rspamd](https://rspamd.com) is a modern, high-performance spam filtering system:

- Run rspamd in its own container (official `rspamd/rspamd` image)
- Rspamd exposes a SpamAssassin-compatible `spamd` proxy on port 783 — simscan's
  `spamc` client connects to it without modification
- Rspamd handles: Bayes, DKIM signing/verification, SPF, DMARC, greylisting,
  RBL, fuzzy hashes — consider disabling jgreylist in favour of Rspamd's
  built-in greylisting
- Redis is required for Bayes and greylisting state — add a `redis` container
- Rspamd web UI is available on port 11334

---

### Simscan (qmail-queue glue layer)

[Simscan](https://github.com/sagredo-dev/simscan) (v1.4.6.2, Roberto's fork) is
the `qmail-queue` wrapper that ties qmail to ClamAV and Rspamd. It rejects
viruses, spam, and bad attachments during the SMTP conversation.

**Integration model:**

```
qmail-smtpd
    └── QMAILQUEUE=simscan
            ├── clamdscan ──TCP──► clamd   (clamav container :3310)
            └── spamc     ──TCP──► rspamd  (rspamd container :783 spamd proxy)
```

**Remote ClamAV support:**

Simscan calls `clamdscan` (the CLI client) rather than talking to `clamd`
directly. `clamdscan` reads `/etc/clamav/clamd.conf` for its connection config.
Pointing `TCPAddr` + `TCPSocket` at the clamav container is all that is needed:

```
# /etc/clamav/clamd.conf inside the qmail container
TCPAddr   clamav   # compose service name
TCPSocket 3310
```

Only the `clamav-daemon` package (which provides the `clamdscan` binary) needs
to be installed in the qmail container — `clamd` itself does not run there.

**Remote Rspamd support:**

Rspamd includes a SpamAssassin-compatible `spamd` proxy. Simscan's `spamc`
client connects to it with `--connect=rspamd:783` — no local spamd needed in
the qmail container.

**Build steps (to be added to Dockerfile):**

- Install `ripMIME` (required): compile from source, install to `/usr/local/bin/`
- Install `clamav-daemon` package (for `clamdscan` binary only)
- Install `spamc` package (for Rspamd client)
- Compile simscan with:
  ```
  --enable-user=clamav
  --enable-clamav=y
  --enable-clamdscan=/usr/bin/clamdscan
  --enable-spam=y
  --enable-spam-passthru=y
  --enable-spam-hits=9.0
  --enable-per-domain=y
  --enable-ripmime
  --enable-attach=y
  --enable-custom-smtp-reject=y
  --enable-spamc-user=y
  --enable-received=y
  ```
- Create work dir: `/var/qmail/simscan` owned by `clamav:clamav`
- Add `simcontrol` control file (domain-specific scan rules)
- Enable via tcprules: `QMAILQUEUE="/var/qmail/bin/simscan"`

**simcontrol format:**

```
user@domain.com:clam=yes,spam=yes,spam_hits=9.0,attach=.vbs:.lnk:.scr
domain.com:clam=yes,spam=yes,spam_hits=7.0
:clam=yes,spam=yes,spam_hits=9.0,size_limit=10000000
```

After changes: run `simscanmk` to recompile the CDB.

---

### Suggested compose stack

```
qmail        — MTA, IMAP/POP3, web admin (this image)
mariadb      — vpopmail auth backend (optional, replaces CDB)
clamav       — clamd antivirus daemon (TCP :3310)
rspamd       — spam + DKIM + DMARC + greylisting (spamd proxy :783, UI :11334)
redis        — Rspamd state (Bayes, greylisting)
```

Simscan runs inside the qmail container and connects to `clamav` and `rspamd`
over the compose network — no shared volumes or Unix sockets required.
