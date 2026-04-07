# Docker TODO

## Target multi-container architecture

The goal is a clean split with **no shared volumes between qmail and Dovecot**.
The key enabler is the **MySQL backend** — it eliminates all filesystem coupling
between the MTA and the IMAP server.

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

**No shared volume between qmail and Dovecot** — MariaDB is the only shared
resource between them (over TCP).

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

## Step 1 — MariaDB (vpopmail auth backend)

- Spin up a `mariadb` container
- Rebuild the qmail image with `--build-arg VPOPMAIL_AUTH=mysql`
- Pass DB credentials via env vars (`MYSQL_HOST`, `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_DB`)
- Write `vpopmail/etc/vpopmail.mysql` from those vars in the entrypoint
- qmailadmin, vqadmin, chkuser, and vusaged all pick up the MySQL backend automatically

---

## Step 2 — Dovecot split (depends on Step 1)

Move Dovecot into its own container:

- Dovecot authenticates via `driver = sql` pointing at MariaDB — no vchkpw needed
- Dovecot receives mail via **LMTP** on TCP port 24 — no `dovecot-lda` binary in qmail container
- Dovecot owns the Maildir volume exclusively — qmail never touches it
- qmail container delivers via a small LMTP client script in `.qmail-default`:

```python
#!/usr/bin/env python3
import sys, os, smtplib
host, port, recipient = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sender = os.environ.get('SENDER', '')
message = sys.stdin.buffer.read()
with smtplib.LMTP(host, port) as s:
    refused = s.sendmail(sender, [recipient], message)
    sys.exit(1 if refused else 0)
```

- Dovecot LMTP config:
```
service lmtp {
  inet_listener lmtp {
    port = 24
  }
}
protocol lmtp {
  mail_plugins = $mail_plugins sieve
}
```

Sieve filtering continues to work — Dovecot runs it natively on LMTP delivery.

---

## Step 3 — ClamAV (antivirus)

[ClamAV](https://www.clamav.net) in its own container:

- Run `clamav/clamav` (`clamd` + `freshclam`)
- `clamd` listens on TCP port 3310
- `freshclam` keeps virus definitions updated automatically
- In the qmail container, configure `/etc/clamav/clamd.conf` with:
  ```
  TCPAddr   clamav
  TCPSocket 3310
  ```
- Install only `clamav-daemon` package in qmail container (provides `clamdscan` client binary)

---

## Step 4 — Rspamd (spam filtering)

[Rspamd](https://rspamd.com) in its own container:

- Official `rspamd/rspamd` image
- Exposes SpamAssassin-compatible `spamd` proxy on port 783 (simscan's `spamc` connects without modification)
- Handles: Bayes, DKIM, SPF, DMARC, greylisting, RBL, fuzzy hashes
- Consider disabling jgreylist in favour of Rspamd's built-in greylisting
- Requires a `redis` container for Bayes and greylisting state
- Web UI on port 11334

---

## Step 5 — Simscan (qmail-queue glue for ClamAV + Rspamd)

[Simscan](https://github.com/sagredo-dev/simscan) (v1.4.6.2) is the
`qmail-queue` wrapper that connects qmail to ClamAV and Rspamd. It rejects
viruses, spam, and bad attachments during the SMTP conversation.

```
qmail-smtpd
    └── QMAILQUEUE=simscan
            ├── clamdscan ──TCP──► clamd   (clamav :3310)
            └── spamc     ──TCP──► rspamd  (rspamd :783)
```

**Build steps (to be added to Dockerfile):**

- Compile `ripMIME` from source, install to `/usr/local/bin/`
- Install `clamav-daemon` (for `clamdscan`) and `spamc` packages
- Compile simscan:
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
- Create `/var/qmail/simscan` owned by `clamav:clamav`
- Add `simcontrol` (domain-specific rules), compile with `simscanmk`
- Enable via tcprules: `QMAILQUEUE="/var/qmail/bin/simscan"`

**simcontrol format:**
```
user@domain.com:clam=yes,spam=yes,spam_hits=9.0,attach=.vbs:.lnk:.scr
domain.com:clam=yes,spam=yes,spam_hits=7.0
:clam=yes,spam=yes,spam_hits=9.0,size_limit=10000000
```

---

## Final compose stack

```
qmail        — MTA + vpopmail + qmailadmin/vqadmin + simscan   ports: 25, 80, 465, 587
dovecot      — IMAP/POP3/ManageSieve + LMTP                    ports: 110, 143, 993, 995, 4190, 24
mariadb      — vpopmail user/domain/password/quota data         port:  3306
clamav       — clamd antivirus                                  port:  3310
rspamd       — spam filtering + DKIM + DMARC + greylisting      ports: 783, 11334
redis        — Rspamd state (Bayes, greylisting)                port:  6379
```
