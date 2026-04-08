# Docker TODO

## Target multi-container architecture

The goal is a clean split with **minimal shared volumes between qmail and Dovecot**.
The key enabler is the **MySQL backend** — it eliminates most filesystem coupling
between the MTA and the IMAP server. Only the Maildir volume is shared (both need
write access for domain creation and mail delivery).

```
┌──────────────────────────────────────┐
│  qmail  (MTA core)                   │  ports 25, 80, 465, 587
│                                      │
│  chkuser ──────────────────────────► │
│  qmailadmin/vqadmin ───────────────► │──── TCP ──► mariadb :3306
│  LMTP client ──────────────────────► │
│                  │                   │
│                  └── TCP ──► dovecot :24
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│  dovecot                             │  ports 110, 143, 993, 995, 4190
│                                      │
│  SQL auth ─────────────────────────► │──── TCP ──► mariadb :3306
│  LMTP listener ◄── qmail            │
│  Maildir volume (owned exclusively)  │
└──────────────────────────────────────┘

┌──────────┐  ┌──────────┐  ┌─────┐  ┌─────────┐
│  clamav  │  │  rspamd  │  │redis│  │ mariadb │
│  :3310   │  │:783/:11334│ │:6379│  │  :3306  │
└──────────┘  └──────────┘  └─────┘  └─────────┘
```

**Minimal shared volumes** — `dovecot_mail` is shared for Maildirs (qmail creates
domains, Dovecot writes mail). MariaDB handles all auth/user data over TCP.

---

## Why MySQL is the prerequisite for everything

| Problem | CDB | MySQL |
|---|---|---|
| chkuser recipient validation | needs shared vpopmail/domains volume | queries MariaDB directly — no shared volume |
| Dovecot authentication | vchkpw needs shared vpopmail binary + data | SQL driver queries MariaDB directly |
| vusaged quota tracking | cache goes stale when Dovecot deletes mail | quota stored in DB — both containers update it |
| qmail ↔ Dovecot coupling | shared filesystem | zero — only TCP to MariaDB |

MySQL backend must be implemented before the container split is attempted.

---

## ✅ Step 1 — MariaDB (vpopmail auth backend) — build verified

- [x] Spin up a `mariadb` container with healthcheck
- [x] Rebuild the qmail image with `--build-arg VPOPMAIL_AUTH=mysql`
- [x] Pass DB credentials via env vars (`MYSQL_HOST`, `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_DB`)
- [x] Write `vpopmail/etc/vpopmail.mysql` from those vars in the entrypoint (format: `host|port|user|password|database`)
- [x] vpopmail configure flags: `--enable-mysql-limits`, `--enable-valias`, `--enable-sql-aliasdomains`, `--enable-incdir=/usr/include/mysql`, `--enable-libdir=/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)`
- [x] MariaDB credentials via `.env` file — compose auto-loads it
- [x] qmail service `depends_on: mariadb: condition: service_healthy`
- [x] Separate greylisting database (`greylisting` DB + user) initialised by `mariadb-init/01-greylisting.sh`
- [x] qmail-spp MySQL-backed greylisting plugin (`plugins/greylisting` + `plugins/ifauthskip`) built into image
- [x] All env vars documented in `docker-compose.yml` and `.env.example`
- [x] qmailadmin built with cracklib password strength checking (`libcrack2-dev` + `cracklib-runtime` in builder; dictionary at `/var/cache/cracklib/cracklib_dict`)
- [x] Rate limiting via `rcptcheck-overlimit` on ports 587 and 465
- [x] `FORCETLS=1` on port 587; `DROP_PRE_GREET`, `SURBL`, `ENABLE_SPP` consistent across all three SMTP ports
- [x] Full image build passes cleanly on `debian:bookworm-slim`

---

## ✅ Step 2 — Dovecot split (depends on Step 1) — implemented

- [x] Dovecot in separate container (`docker/dovecot/`)
- [x] SQL auth via `driver = sql` pointing at MariaDB — no vchkpw binary needed
- [x] LMTP listener on TCP port 24 for mail delivery from qmail
- [x] Shared `dovecot_mail` volume for Maildirs (both containers have write access)
- [x] Read-only mount of `maildata` volume for TLS certs and Sieve scripts
- [x] SQL userdb query translates paths (`/home/vpopmail/domains` → `/srv/mail/vpopmail/domains`)
- [x] Bash LMTP client script (`/var/qmail/bin/lmtp-deliver`) using `/dev/tcp` — faster than Python
- [x] Service toggles via env vars:
  - `DOVECOT_IMAP`, `DOVECOT_IMAPS`, `DOVECOT_POP3`, `DOVECOT_POP3S`, `DOVECOT_SIEVE`, `DOVECOT_LMTP`
  - `QMAIL_SMTP`, `QMAIL_SMTPS`, `QMAIL_SUBMISSION`, `QMAIL_HTTP`
- [x] Default: SSL ports enabled, plaintext ports disabled
- [x] Healthchecks respect service toggles
- [x] Sieve filtering works via LMTP delivery

---

## ✅ Step 3 — ClamAV (antivirus) — implemented

- [x] `clamav/clamav:latest` container — runs `clamd` + `freshclam` in one image
- [x] `clamd` listens on TCP port 3310 (internal only — not exposed to host)
- [x] `freshclam` keeps virus definitions updated automatically
- [x] `clamav_data` volume persists definitions across restarts (~250 MB)
- [x] Healthcheck via `/usr/local/bin/clamdcheck.sh`; `start_period: 300s` (definition load)
- [x] `clamav` + `clamav-daemon` added to qmail runtime stage (ClamAV 1.4.x removed standalone `clamdscan`)
- [x] `docker/clamdscan-wrapper` (Python3 INSTREAM client) installed as `/usr/bin/clamdscan` — reads `CLAMD_HOST`/`CLAMD_PORT`
- [x] `docker/clamdscan.conf` → `/etc/clamav/clamd.conf` (TCPAddr clamav, TCPSocket 3310) — legacy path kept for reference
- [x] simscan wires `clamdscan` into the queue in Step 5

---

## ✅ Step 4 — Rspamd + Redis — implemented

- [x] `redis:7-alpine` container with healthcheck; data in `redis_data` volume
- [x] `rspamd/rspamd:latest` container depending on redis healthcheck
- [x] Redis backend for all modules (`local.d/redis.conf`)
- [x] Bayes classifier with Redis backend + autolearn (`local.d/classifier-bayes.conf`)
- [x] Greylisting disabled — handled by qmail-spp MySQL plugin (`local.d/greylist.conf`)
- [x] DKIM signing disabled — handled by qmail-dkim; verification remains active (`local.d/dkim_signing.conf`)
- [x] Web UI on port 11334 (`RSPAMD_PASSWORD` env var; hash via `rspamadm pw`)
- [x] SPF, DMARC, RBL checks enabled by default (built into rspamd)
- [x] Port 783 (spamc) is internal-only — simscan integration wired in Step 5

---

## ✅ Step 5 — Simscan (qmail-queue glue for ClamAV + Rspamd) — implemented

[Simscan](https://github.com/sagredo-dev/simscan) (v1.4.6.2) is the
`qmail-queue` wrapper that connects qmail to ClamAV and Rspamd. It rejects
viruses, spam, and bad attachments during the SMTP conversation.

```
qmail-smtpd
    └── QMAILQUEUE=qmail-dkim  (DKIM verify)
          └── DKIMQUEUE=simscan
                  ├── /usr/bin/clamdscan ──INSTREAM──► clamd   (clamav :3310)
                  └── /usr/local/bin/rspamd-spamc ────HTTP──► rspamd  (rspamd :11333)
                        └── /var/qmail/bin/qmail-queue
```

- [x] `ripMIME` compiled from source → `/usr/local/bin/ripMIME`
- [x] `rspamd` installed in runtime stage for `/usr/bin/rspamc` client binary (daemon runs in its own container)
- [x] `docker/rspamd-spamc` wrapper: calls `rspamc -h rspamd:11333`, inserts `X-Spam-*` headers, passes through on rspamd down
- [x] `docker/clamdscan-wrapper` (Python3): implements ClamAV INSTREAM protocol over TCP; pass-through if clamd down
- [x] simscan compiled with `--enable-spamc=/usr/local/bin/rspamd-spamc`, `--enable-clamdscan=/usr/bin/clamdscan`
- [x] clamav user + group created in builder for configure checks; clamav-daemon creates them in runtime
- [x] `/var/qmail/simscan` volume-linked (`/srv/mail/qmail/simscan`), owned by `clamav:clamav`, setuid binary
- [x] `simcontrol` written on first run from env vars; `simscanmk` runs every startup
- [x] Delivery chain: `QMAILQUEUE=qmail-dkim` → `DKIMQUEUE=simscan` → `qmail-queue` (all three SMTP ports)
- [x] `SIMSCAN_ENABLE=false` bypasses `DKIMQUEUE` entirely — mail flows direct to queue without scanning

**Simscan env vars:**

| Variable | Default | Description |
|---|---|---|
| `SIMSCAN_ENABLE` | `true` | Master toggle — `false` disables scanning on all ports |
| `SIMSCAN_CLAM` | `yes` | ClamAV scanning in simcontrol |
| `SIMSCAN_SPAM` | `yes` | Rspamd spam scanning in simcontrol |
| `SIMSCAN_SPAM_HITS` | `9.0` | Spam score threshold |
| `SIMSCAN_SIZE_LIMIT` | `20000000` | Max message bytes to scan |
| `SIMSCAN_ATTACH` | — | Blocked attachment extensions, semicolon-separated (e.g. `.vbs;.lnk;.scr`) |
| `SIMSCAN_DEBUG` | `0` | Debug verbosity 0–4 |
| `CLAMD_HOST` | `clamav` | clamd container hostname |
| `CLAMD_PORT` | `3310` | clamd TCP port |
| `RSPAMD_HOST` | `rspamd` | rspamd container hostname |
| `RSPAMD_PORT` | `11333` | rspamd HTTP API port |

---

## ✅ Step 6 — IMAPSieve spam/ham learning (Dovecot → rspamd)

When a user moves a message to/from a Junk or Spam folder via IMAP, Dovecot
fires a Sieve script that pipes the message to rspamd's HTTP API for Bayes
learning. The authenticated username is forwarded so rspamd tracks per-user
classifier state in Redis.

```
User moves message to Junk/Spam
  → imap_sieve plugin fires learn-spam.sieve
    → pipe :args ["user@example.com"] "learn-spam.sh"
      → curl POST http://rspamd:11333/learn_spam  (User: user@example.com)

User moves message out of Junk/Spam (not to Trash)
  → imap_sieve plugin fires learn-ham.sieve
    → pipe :args ["user@example.com"] "learn-ham.sh"
      → curl POST http://rspamd:11333/learn_ham   (User: user@example.com)
```

- [x] `imap_sieve` plugin enabled in `protocol imap { mail_plugins }`
- [x] `sieve_imapsieve` + `sieve_extprograms` added to Sieve plugin block
- [x] 4 mailbox rules: COPY to `Junk`/`Spam` → learn spam; COPY from `Junk`/`Spam` (not to Trash) → learn ham
- [x] `docker/dovecot/sieve/learn-spam.sieve` + `learn-ham.sieve` — IMAPSieve scripts
- [x] `imap.user` captured via `environment :matches` and passed as `:args ["${username}"]`
- [x] `docker/dovecot/sieve/scripts/learn-spam.sh` + `learn-ham.sh` — curl to rspamd HTTP API
- [x] `User: <username>` header on every learn request — per-user Bayes state in Redis
- [x] `/etc/dovecot/sieve/rspamd.env` written at runtime by entrypoint.sh (`chmod 600`) — credentials out of scripts
- [x] Sieve scripts pre-compiled with `sievec` in Dockerfile — syntax errors caught at build time
- [x] `curl` added to Dovecot Dockerfile
- [x] `RSPAMD_HOST`, `RSPAMD_PORT`, `RSPAMD_PASSWORD` added to dovecot service in compose

---

## Final compose stack

```
qmail        — MTA + vpopmail + qmailadmin/vqadmin + simscan   ports: 25, 80, 465, 587
dovecot      — IMAP/POP3/ManageSieve + LMTP                    ports: 110, 143, 993, 995, 4190
mariadb      — vpopmail user/domain/password/quota data         port:  3306  (internal)
clamav       — clamd antivirus                                  port:  3310  (internal)
rspamd       — spam filtering, DKIM verify, DMARC, RBL          port:  11334 (web UI)
redis        — Rspamd Bayes + fuzzy state                       port:  6379  (internal)
```
