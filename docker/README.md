# qmail Docker

Containerised build of [sagredo-dev/qmail](https://github.com/sagredo-dev/qmail) —
a heavily patched netqmail-1.06 with TLS, DKIM, SPF, SRS, SMTP AUTH, chkuser,
SURBL, greylisting, simscan and more — running under **runit** on **Debian bookworm-slim**.

The compose stack runs six containers:

| Container | Role | Ports |
|---|---|---|
| **qmail** | MTA — SMTP, submission, qmailadmin, vqadmin, simscan | 25, 80, 465, 587 |
| **dovecot** | IMAP/POP3/ManageSieve, LMTP delivery endpoint | 110, 143, 993, 995, 4190 |
| **mariadb** | vpopmail auth/quota backend | internal |
| **clamav** | `clamd` + `freshclam` antivirus | internal :3310 |
| **rspamd** | Spam filtering, DKIM verify, DMARC, RBL, Bayes | :11334 (web UI) |
| **redis** | Rspamd Bayes + fuzzy state | internal |

---

## Build chain

The compilation order is strictly enforced because each step depends on the
previous one being installed:

```
fehQlibs → ucspi-tcp6 → ucspi-ssl → libsrs2 → netqmail → vpopmail → autorespond
         → patched qmail → jgreylist → spp-greylisting + ifauthskip
         → ripMIME → simscan → ezmlm-idx → qmailadmin → vqadmin
```

| Step | Why it must come first |
|---|---|
| **fehQlibs** | DJB-style headers/libs required by ucspi-tcp6 v1.13+ |
| **ucspi-tcp6** | `tcpserver` with IPv6 dual-stack support for SMTP ports |
| **ucspi-ssl** | `sslserver` binary for implicit TLS (SMTPS port 465) |
| **libsrs2** | qmail links against it at compile time (`conf-ld: -L/usr/local/lib`) |
| **netqmail** | creates `/var/qmail` layout before vpopmail's `configure` runs |
| **vpopmail** | `chkuser.c` includes `vpopmail.h`/`vauth.h`; qmail-smtpd links against `/home/vpopmail/etc/lib_deps` |
| **autorespond** | vacation responder required by qmailadmin |
| **patched qmail** | overwrites netqmail binaries |
| **jgreylist** | file-based greylisting wrapper compiled into `/var/qmail/bin/` |
| **spp-greylisting + ifauthskip** | MySQL-backed greylisting plugin + auth-skip plugin compiled into `/var/qmail/plugins/` |
| **ripMIME** | MIME extractor required by simscan for attachment scanning |
| **simscan** | `qmail-queue` filter — scans via ClamAV + Rspamd before queueing |
| **ezmlm-idx** | mailing list manager, used by qmailadmin |
| **qmailadmin** | web UI for domain/user management |
| **vqadmin** | system-level domain admin |

---

## Quick start

### 1. Configure credentials

Copy the example env file and set at minimum the MariaDB passwords and your
server's FQDN:

```sh
cp docker/.env.example docker/.env
$EDITOR docker/.env
```

The only truly required change is `QMAIL_ME`. You should also set strong
passwords for `MYSQL_PASS`, `MYSQL_ROOT_PASS`, and `MYSQL_PASS`.

### 2. Build and start

The image builds cleanly on `debian:bookworm-slim`. Full build time is roughly
5–10 minutes on first run (all sources downloaded and compiled from scratch).

```sh
git clone https://github.com/brdelphus/qmail
cd qmail

docker compose -f docker/docker-compose.yml build
docker compose -f docker/docker-compose.yml up -d
docker compose -f docker/docker-compose.yml logs -f
```

On first run the entrypoint will:
- Write all qmail control files from env vars
- Write `vpopmail/etc/vpopmail.mysql` for MariaDB auth
- Generate a self-signed TLS cert for `QMAIL_ME` (replace with Let's Encrypt — see TLS section)
- Generate DKIM keys for `QMAIL_DOMAIN`
- Create the primary vpopmail domain
- Set up tcprules CDB files
- Write `simscan/simcontrol` from `SIMSCAN_*` env vars and compile with `simscanmk`

### 3. Add the first mail user

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /home/vpopmail/bin/vadduser postmaster@example.com yourpassword
```

### DNS records needed

| Type | Name | Value |
|---|---|---|
| A / AAAA | `mail.example.com` | server IP |
| MX | `example.com` | `mail.example.com` (priority 10) |
| TXT | `_domainkey.example.com` | contents of `/srv/mail/qmail/control/domainkeys/example.com.dns.txt` |
| TXT | `example.com` | `v=spf1 mx ~all` |

---

## vpopmail auth backend

vpopmail is compiled with a single auth backend selected at build time.
The compose file defaults to **MySQL** (MariaDB). The Dockerfile accepts any backend:

| Backend | Build arg | Extra runtime dependency |
|---|---|---|
| `mysql` *(default)* | `VPOPMAIL_AUTH=mysql` | MariaDB / MySQL server |
| `cdb` | `VPOPMAIL_AUTH=cdb` | *(none)* |
| `pgsql` | `VPOPMAIL_AUTH=pgsql` | PostgreSQL server |
| `ldap` | `VPOPMAIL_AUTH=ldap` | LDAP server |
| `passwd` | `VPOPMAIL_AUTH=passwd` | *(none)* |

All client dev libraries are installed in the builder stage. To switch backends,
rebuild with a different arg (and remove the `mariadb` service if not using MySQL):

```sh
docker compose -f docker/docker-compose.yml build \
    --build-arg VPOPMAIL_AUTH=cdb
```

> **Debian note:** the MySQL backend requires `--enable-libdir` pointing at the
> multiarch lib path (`/usr/lib/x86_64-linux-gnu` on amd64). The Dockerfile
> derives this automatically via `dpkg-architecture -qDEB_HOST_MULTIARCH`.

### vpopmail.mysql

When `MYSQL_HOST` is set, the entrypoint writes
`/home/vpopmail/etc/vpopmail.mysql` on every startup:

```
host|port|user|password|database
```

This file is re-written on every container start so credential changes take
effect without rebuilding.

---

## MariaDB

The `mariadb` service is a prerequisite for the qmail container — qmail's
`depends_on` waits for the MariaDB healthcheck to pass before starting.

### Databases

| Database | User | Purpose |
|---|---|---|
| `vpopmail` | `vpopmail` | Domain/user/password/quota data for vpopmail, chkuser, qmailadmin, vqadmin |
| `greylisting` | `greylisting` | Triplet state for the qmail-spp greylisting plugin |

Both are created automatically on the first MariaDB start via scripts in
`docker/mariadb-init/`:

- `01-greylisting.sh` — creates the `greylisting` DB, user, and table schema

### Credentials

Set in `.env` (shared between the `mariadb` and `qmail` services):

```
MYSQL_ROOT_PASS=changeme_root
MYSQL_DB=vpopmail
MYSQL_USER=vpopmail
MYSQL_PASS=changeme
```

> **Important:** change all passwords before the first run — they are baked
> into the database volume and cannot be changed by simply editing `.env` after
> the volume has been initialised.

---

## Persistent volume

All mutable data lives under **named volumes** mounted at fixed paths.
On first run the entrypoint seeds each subdirectory from the image defaults
and replaces the original paths with symlinks.

| Volume | Mount path | Contents |
|---|---|---|
| `maildata:/srv/mail/qmail/control` | `/var/qmail/control` | Control files, TLS certs, DKIM keys, tcprules CDBs, Sieve globals |
| `maildata:/srv/mail/qmail/queue` | `/var/qmail/queue` | Mail queue |
| `maildata:/srv/mail/qmail/overlimit` | `/var/qmail/overlimit` | Per-user send-rate counters |
| `maildata:/srv/mail/qmail/simscan` | `/var/qmail/simscan` | `simcontrol` + compiled `simcontrol.cdb` |
| `maildata:/srv/mail/jgreylist` | `/var/qmail/jgreylist` | jgreylist state files |
| `maildata:/srv/mail/vpopmail/domains` | `/home/vpopmail/domains` | Virtual domain Maildirs (shared with Dovecot) |
| `maildata:/srv/mail/vpopmail/etc` | `/home/vpopmail/etc` | vpopmail config and DB connection strings |
| `mariadb_data` | `/var/lib/mysql` | MariaDB data directory |
| `clamav_data` | `/var/lib/clamav` | ClamAV virus definitions (~250 MB) |
| `rspamd_data` | `/var/lib/rspamd` | Rspamd state and learned data |
| `redis_data` | `/data` | Redis Bayes + fuzzy hash state |

### Backup

```sh
# qmail volume
docker run --rm \
    -v maildata:/srv/mail \
    -v $(pwd):/backup \
    debian:bookworm-slim \
    tar czf /backup/maildata-$(date +%F).tar.gz /srv/mail

# MariaDB
docker compose -f docker/docker-compose.yml exec mariadb \
    mariadb-dump -u root -p"$MYSQL_ROOT_PASS" --all-databases \
    > backup-$(date +%F).sql
```

---

## Environment variables

All variables can be set in `docker/.env` — Docker Compose loads it
automatically. See `.env.example` for a fully commented reference.

### Server identity

| Variable | Default | Description |
|---|---|---|
| `QMAIL_ME` | **required** | FQDN of this server (`mail.example.com`) |
| `QMAIL_DOMAIN` | derived from `QMAIL_ME` | Primary virtual domain, created in vpopmail on first run |

### MariaDB

| Variable | Default | Description |
|---|---|---|
| `MYSQL_HOST` | `mariadb` | MariaDB hostname (service name — do not change) |
| `MYSQL_PORT` | `3306` | MariaDB port |
| `MYSQL_DB` | `vpopmail` | vpopmail database name |
| `MYSQL_USER` | `vpopmail` | vpopmail database user |
| `MYSQL_PASS` | `changeme` | vpopmail database password |
| `MYSQL_ROOT_PASS` | `changeme_root` | MariaDB root password |

### Queue / concurrency

| Variable | Default | Description |
|---|---|---|
| `QMAIL_SOFTLIMIT` | `64000000` | Memory limit in bytes per SMTP process |
| `QMAIL_CONCURRENCY_INCOMING` | `200` | Max simultaneous inbound SMTP connections |
| `QMAIL_CONCURRENCY_REMOTE` | `20` | Max simultaneous outbound deliveries |
| `QMAIL_CONCURRENCY_LOCAL` | `10` | Max simultaneous local deliveries |
| `QMAIL_DATABYTES` | `20000000` | Max message size in bytes (`0`=unlimited) |
| `QMAIL_MAXRCPT` | `100` | Max recipients per message |
| `QMAIL_QUEUELIFETIME` | `272800` | Seconds a message stays in queue before bouncing (~3 days) |

### SMTP behaviour

| Variable | Default | Description |
|---|---|---|
| `QMAIL_SPFBEHAVIOR` | `3` | SPF: `0`=off, `1`=neutral, `2`=softfail, `3`=fail→reject |
| `QMAIL_GREETDELAY` | `5` | Seconds to delay SMTP greeting (anti-spam) |
| `QMAIL_SURBL` | `0` | SURBL URI blocklist filtering (`0`=off, `1`=on) |
| `QMAIL_CHKUSER_WRONGRCPTLIMIT` | `3` | Max invalid recipients before disconnect (all ports) |
| `QMAIL_BRTLIMIT` | `2` | Max non-existent recipients before disconnect (brtlimit patch) |
| `QMAIL_BOUNCEFROM` | `noreply` | Envelope sender name for bounce messages |
| `QMAIL_RELAY_LIMIT` | `1000` | Max messages an auth user/domain/IP may send per period (`0`=unlimited) |
| `QMAIL_DUALSTACK` | `0` | Bind on `::` for IPv4+IPv6 dual-stack (`1`=on, requires Docker IPv6) |
| `QMAIL_GREYLISTING` | `0` | Enable jgreylist binary wrapper on port 25 (`1`=on) |
| `QMAIL_SPF_EXP` | — | Custom SPF failure explanation message (optional) |

### SMTP run-script env vars (passed to qmail-smtpd)

| Variable | Default | Description |
|---|---|---|
| `UNSIGNED_SUBJECT` | `1` | Allow DKIM-signed mail where Subject is absent from `h=` tag |
| `HELO_DNS_CHECK` | — | HELO hostname DNS validation modes (e.g. `PLRIV`) |
| `REJECTNULLSENDERS` | — | Reject messages with empty envelope sender (`<>`) when set |

### TLS

| Variable | Default | Description |
|---|---|---|
| `QMAIL_TLS_CERT` | — | Path to TLS certificate PEM (e.g. Let's Encrypt `fullchain.pem`) |
| `QMAIL_TLS_KEY` | — | Path to TLS private key PEM |
| `QMAIL_DH_BITS` | `2048` | DH parameter bit size (`2048` or `4096`) |
| `QMAIL_TLS_CIPHERS` | `HIGH:MEDIUM:!MD5:!RC4:!3DES:!LOW:!SSLv2:!SSLv3` | Allowed TLS cipher suite |
| `QMAIL_SNI_CERTS` | — | Semicolon-separated `domain:cert:key` triplets for SNI (see TLS section) |

### Relay / access control

| Variable | Default | Description |
|---|---|---|
| `QMAIL_RELAY_NETS` | — | Comma-separated IPs/prefixes trusted to relay on port 25 |
| `QMAIL_TAPS` | — | Semicolon-separated tap rules `TYPE:REGEX:DEST` (`F`=from, `T`=to, `A`=all) |

### qmail-spp greylisting plugin

| Variable | Default | Description |
|---|---|---|
| `GREYLIST_USER` | — | Database user — **set this to enable the plugin** |
| `GREYLIST_PASS` | `changeme_grey` | Database password |
| `GREYLIST_DB` | `greylisting` | Database name |
| `GREYLIST_HOST` | `mariadb` | Database host |
| `GREYLIST_BLOCK_EXPIRE` | `2` | Minutes a new sender is greylisted |
| `GREYLIST_RECORD_EXPIRE` | `2000` | Minutes until an unseen triplet is purged |
| `GREYLIST_RECORD_EXPIRE_GOOD` | `36` | Hours a good sender stays whitelisted |
| `GREYLIST_LOGLEVEL` | `4` | Plugin log verbosity |

### Web admin

| Variable | Default | Description |
|---|---|---|
| `VQADMIN_USER` | `admin` | vqadmin HTTP basic auth username |
| `VQADMIN_PASS` | auto-generated | vqadmin password — printed to logs on first run if not set |

---

## Exposed ports

| Port | Protocol | Service |
|---|---|---|
| `25` | SMTP | Inbound mail |
| `80` | HTTP | qmailadmin web interface |
| `110` | POP3 | Mail retrieval |
| `143` | IMAP | Mail retrieval (Dovecot) |
| `465` | SMTPS | SMTP over implicit TLS |
| `587` | Submission | Authenticated outbound (STARTTLS required) |
| `993` | IMAPS | IMAP over TLS (Dovecot) |
| `995` | POP3S | POP3 over TLS (Dovecot) |
| `4190` | ManageSieve | Sieve script management (Dovecot) |

---

## Runit services

The **qmail** container runs six supervised services under `runsvdir`:

| Service | Port | Notes |
|---|---|---|
| `qmail-smtpd` | 25 | chkuser, SPF, SURBL, DKIM verify → simscan → queue; optional jgreylist + spp greylisting |
| `qmail-send` | — | Queue manager; DKIM signing via `control/filterargs` at remote delivery |
| `qmail-submission` | 587 | Auth required (`SMTPAUTH=!`), `FORCETLS=1`, rate limiting, simscan |
| `qmail-smtps` | 465 | Auth required, implicit TLS via `sslserver`, rate limiting, simscan |
| `lighttpd` | 80 | qmailadmin + vqadmin CGI |
| `vusaged` | — | vpopmail quota usage daemon |

IMAP/POP3/Sieve run in the **dovecot** container (see Dovecot section below).

Logs are written via `svlogd` to `/var/log/qmail/<service>/`.

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    sv status /etc/service/*
```

---

## TLS certificates

Both qmail (`sslserver`) and Dovecot read a combined PEM at
`/var/qmail/control/servercert.pem` (certificate block first, then private key).
DH parameters are stored at `/var/qmail/control/dh4096.pem`.

| Priority | Condition | Result |
|---|---|---|
| 1 | `QMAIL_TLS_CERT` + `QMAIL_TLS_KEY` set | Combines the two files into `servercert.pem` |
| 2 | `servercert.pem` already in volume | Used as-is |
| 3 | Neither | Self-signed cert generated for `QMAIL_ME` |

### Let's Encrypt

```yaml
environment:
  QMAIL_TLS_CERT: /etc/letsencrypt/live/mail.example.com/fullchain.pem
  QMAIL_TLS_KEY:  /etc/letsencrypt/live/mail.example.com/privkey.pem
volumes:
  - /etc/letsencrypt:/etc/letsencrypt:ro
  - maildata:/srv/mail
```

On cert renewal, restart to re-combine the PEM:

```sh
docker compose -f docker/docker-compose.yml restart qmail
```

### SNI — multiple domains

```yaml
environment:
  QMAIL_SNI_CERTS: "mail2.example.org:/etc/letsencrypt/live/mail2.example.org/fullchain.pem:/etc/letsencrypt/live/mail2.example.org/privkey.pem"
```

On every startup the entrypoint combines each cert+key into
`control/servercerts/<domain>/servercert.pem` and generates
`control/dovecot-sni.conf` with `local_name` blocks.

---

## Greylisting

Two independent greylisting mechanisms are available and can run simultaneously.

### jgreylist (file-based, port 25 only)

Wraps `qmail-smtpd` as a binary in the port 25 run script. No database required.

```yaml
environment:
  QMAIL_GREYLISTING: 1
```

State files persist in `/srv/mail/jgreylist`. Purge expired entries periodically:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/jgreylist-clean
```

### qmail-spp greylisting plugin (MySQL-backed, all ports)

Runs inside `qmail-smtpd` via the SPP plugin system. Uses the `greylisting`
MariaDB database. Supports per-IP exemptions, pass/block statistics, and
automatic bypass for authenticated users (`ifauthskip`).

**Enable** by setting `GREYLIST_USER` in `.env`:

```
GREYLIST_USER=greylisting
GREYLIST_PASS=strongpassword
GREYLIST_DB=greylisting
```

On first run the entrypoint writes:
- `control/mysql.cnf` — database connection config for the plugin
- `control/greylisting` — plugin settings (block/expire times, log level)
- `control/smtpplugins` — activates `plugins/ifauthskip` and `plugins/greylisting`

The `greylisting` database and schema are created automatically on the first
MariaDB start via `docker/mariadb-init/01-greylisting.sh`.

**Tune** settings via env vars or by editing `control/greylisting` in the volume:

```
mysql_default_file=control/mysql.cnf
block_expire=2          # minutes
record_expire=2000      # minutes
record_expire_good=36   # hours
loglevel=4
```

Purge stale records periodically:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /usr/local/sbin/greylisting_cleanup.sh
```

---

## Rate limiting

`rcptcheck-overlimit` limits how many messages an authenticated user, domain,
or IP may send per reset period. Enabled by default on ports 587 and 465.

The default limit is set by `QMAIL_RELAY_LIMIT` (default: `1000`). On first run
the entrypoint writes `/var/qmail/control/relaylimits`:

```
# Per-user/domain/IP limits — edit directly for overrides
:1000
```

Override per user/domain/IP by editing the file:

```
poweruser@example.com:5000
example.com:2000
1.2.3.4:0          # 0 = unlimited
:1000              # catch-all default
```

Per-period counts are stored in `/srv/mail/qmail/overlimit` (persisted in the
volume). Reset them by purging that directory or running a cron job.

---

## Managing virtual domains and users

```sh
# Add a domain
docker compose -f docker/docker-compose.yml exec qmail \
    /home/vpopmail/bin/vadddomain example.com

# Add a user
docker compose -f docker/docker-compose.yml exec qmail \
    /home/vpopmail/bin/vadduser user@example.com password

# Delete a user
docker compose -f docker/docker-compose.yml exec qmail \
    /home/vpopmail/bin/vdeluser user@example.com

# List users in a domain
docker compose -f docker/docker-compose.yml exec qmail \
    /home/vpopmail/bin/vdominfo example.com
```

---

## DKIM signing and verification

DKIM is automatically configured on first run:

- **Signing**: Outbound mail is signed via `spawn-filter` using keys in `control/domainkeys/<domain>/default`
- **Verification**: Inbound mail verified via `qmail-dkim`; `UNSIGNED_SUBJECT=1` allows messages where Subject is absent from the `h=` tag

### View DKIM DNS record

```
/srv/mail/qmail/control/domainkeys/<domain>.dns.txt
```

Add as `default._domainkey.<domain>` TXT record.

### Generate key for additional domain

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/dknewkey -d newdomain.com -t rsa -b 2048 default
```

---

## DNS blocklists (DNSBL/RBL)

A template `dnsbllist` is created at `/srv/mail/qmail/control/dnsbllist`.
Uncomment and customise blocklists as needed. Prefix with `-` for 553 reject
(vs 451 defer):

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    vi /var/qmail/control/dnsbllist
```

---

## qmailadmin web interface

Access at `http://<server-ip>/`. Login with domain, username, and vpopmail password.

Features: add/edit/delete users and aliases, autoresponders, mail forwarding,
mailing lists (ezmlm-idx), mailbox quotas.

---

## vqadmin (system admin)

Access at `http://<server-ip>/cgi-bin/vqadmin/vqadmin.cgi`. Requires HTTP basic
auth — credentials set via `VQADMIN_USER` / `VQADMIN_PASS` (auto-generated and
printed to logs on first run if not set).

```sh
# Change password on running container
docker compose -f docker/docker-compose.yml exec qmail \
    htpasswd /var/qmail/control/vqadmin.htpasswd admin
```

---

## Dovecot

Dovecot runs in its own container with SQL authentication against MariaDB (no
`vchkpw` binary needed). Mail is delivered from qmail via **LMTP** on TCP port 24:

```
qmail-local → /var/qmail/bin/lmtp-deliver → dovecot :24 → Sieve → Maildir
```

### Dovecot service toggles

| Variable | Default | Description |
|---|---|---|
| `DOVECOT_IMAP` | `false` | IMAP on port 143 (plaintext) |
| `DOVECOT_IMAPS` | `true` | IMAP over TLS on port 993 |
| `DOVECOT_POP3` | `false` | POP3 on port 110 (plaintext) |
| `DOVECOT_POP3S` | `true` | POP3 over TLS on port 995 |
| `DOVECOT_SIEVE` | `true` | ManageSieve on port 4190 |
| `DOVECOT_LMTP` | `true` | LMTP listener on port 24 (required for mail delivery) |

### Dovecot rspamd env vars

| Variable | Default | Description |
|---|---|---|
| `RSPAMD_HOST` | `rspamd` | rspamd container hostname for spam/ham learning |
| `RSPAMD_PORT` | `11333` | rspamd HTTP API port |
| `RSPAMD_PASSWORD` | `changeme_rspamd` | rspamd controller password (same as `RSPAMD_PASSWORD` in the rspamd service) |

---

## Sieve filtering and ManageSieve

Mail is delivered via **Dovecot LMTP**, enabling Sieve filtering on every
inbound message:

```
qmail-local → lmtp-deliver → dovecot LMTP :24 → Sieve → Maildir
```

ManageSieve (port 4190) lets mail clients upload and manage Sieve scripts.

### Global Sieve scripts

| Directory | Runs |
|---|---|
| `/srv/mail/qmail/control/sieve/before.d/` | Before user's script |
| `/srv/mail/qmail/control/sieve/after.d/` | After user's script |

```sh
# Compile after adding/changing a global script
docker compose -f docker/docker-compose.yml exec qmail \
    sievec /var/qmail/control/sieve/before.d/10-spam.sieve
```

Example spam-to-Junk script — pairs with the IMAPSieve learning below:

```sieve
require ["fileinto", "mailbox"];
if header :contains "X-Spam-Flag" "YES" {
    fileinto :create "Junk";
    stop;
}
```

### Spam/ham learning via folder moves (IMAPSieve)

Moving a message **into** `Junk` or `Spam` via IMAP triggers rspamd Bayes
learning automatically — no client plugin needed. Moving it back out (not to
Trash) teaches ham.

```
Move to Junk/Spam   →  curl POST rspamd:11333/learn_spam  (User: alice@example.com)
Move out of Junk    →  curl POST rspamd:11333/learn_ham   (User: alice@example.com)
```

The authenticated IMAP username is captured by the Sieve script and forwarded
as a `User:` header so rspamd maintains **per-user Bayes** state in Redis.
Users whose mail habits differ (e.g. mailing-list heavy vs. transactional)
each train their own classifier without cross-contamination.

The scripts live in the image at `/etc/dovecot/sieve/` and are pre-compiled at
build time. rspamd credentials are written to `/etc/dovecot/sieve/rspamd.env`
(mode `0600`) at container start from the `RSPAMD_*` env vars — they never
appear in the scripts themselves.

---

## ClamAV + simscan

[ClamAV](https://www.clamav.net) runs `clamd` + `freshclam` in its own container.
[Simscan](https://github.com/sagredo-dev/simscan) is a `qmail-queue` wrapper
built into the qmail image that calls ClamAV and Rspamd before accepting a message.

### Delivery chain

```
qmail-smtpd
  → QMAILQUEUE=qmail-dkim  (DKIM verification)
  → DKIMQUEUE=simscan       (when SIMSCAN_ENABLE=true)
      ├── /usr/bin/clamdscan ──INSTREAM──► clamd :3310
      └── /usr/local/bin/rspamd-spamc ────HTTP──► rspamd :11333
  → /var/qmail/bin/qmail-queue
```

`clamdscan` is a Python3 INSTREAM client (ClamAV 1.x removed the standalone
binary). Both scanners fail open — if the remote daemon is unreachable, mail
passes through unscanned rather than being rejected.

### Simscan env vars

| Variable | Default | Description |
|---|---|---|
| `SIMSCAN_ENABLE` | `true` | Master toggle — `false` bypasses simscan on all ports |
| `SIMSCAN_CLAM` | `yes` | ClamAV scanning |
| `SIMSCAN_SPAM` | `yes` | Rspamd spam scanning |
| `SIMSCAN_SPAM_HITS` | `9.0` | Spam score rejection threshold |
| `SIMSCAN_SIZE_LIMIT` | `20000000` | Max bytes to scan (`0`=unlimited) |
| `SIMSCAN_ATTACH` | — | Blocked attachment extensions, semicolon-separated (e.g. `.vbs;.lnk;.scr`) |
| `SIMSCAN_DEBUG` | `0` | Debug verbosity 0–4 |
| `CLAMD_HOST` | `clamav` | clamd container hostname |
| `CLAMD_PORT` | `3310` | clamd TCP port |

These are written into `/var/qmail/simscan/simcontrol` on first run. To apply
changes on an existing volume, delete the file and restart, or edit it directly
for per-domain overrides:

```
# Format: [user@]domain:option=value,...
user@example.com:clam=yes,spam=yes,spam_hits=6.0,attach=.vbs:.lnk:.scr
example.com:clam=yes,spam=yes,spam_hits=7.0
:clam=yes,spam=yes,spam_hits=9.0,size_limit=20000000
```

After editing, recompile:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/simscanmk
```

---

## Rspamd

[Rspamd](https://rspamd.com) handles spam scoring, DKIM verification, DMARC,
SPF, RBL checks, and Bayes learning (state in Redis). It is called by simscan
via the `rspamd-spamc` wrapper over the HTTP API on port 11333.

Web UI is available at `http://<host>:11334/`.

### Rspamd env var

| Variable | Default | Description |
|---|---|---|
| `RSPAMD_PASSWORD` | `changeme_rspamd` | Web UI password — generate hash with `docker compose exec rspamd rspamadm pw` |
| `RSPAMD_HOST` | `rspamd` | rspamd container hostname (used by rspamd-spamc wrapper) |
| `RSPAMD_PORT` | `11333` | rspamd HTTP API port |

### Setting a proper web UI password

```sh
docker compose -f docker/docker-compose.yml exec rspamd rspamadm pw
# Copy the $2$... hash, then write it to:
# docker/rspamd/local.d/worker-controller.inc
```

```
password = "$2$...hash...";
enable_password = "$2$...hash...";
```

### Rspamd local config

Custom overrides go in `docker/rspamd/local.d/` — mounted read-only into the
container. Files present:

| File | Purpose |
|---|---|
| `redis.conf` | Redis backend for all modules |
| `classifier-bayes.conf` | Bayes with Redis + autolearn |
| `greylist.conf` | Greylisting disabled (qmail-spp handles it) |
| `dkim_signing.conf` | DKIM signing disabled (qmail-dkim handles it) |

---

## tcprules (relay and recipient policy)

| File | Port | Purpose |
|---|---|---|
| `tcp.smtp` | 25 | Inbound — trusted IPs get `RELAYCLIENT=""` |
| `tcp.submission` | 587 | Auth submission — relay gated by `SMTPAUTH` |
| `tcp.smtps` | 465 | Same as submission over implicit TLS |

CDB files are seeded once on first run. To update rules on a live container:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    sh -c 'vi /var/qmail/control/tcp.smtp && \
           tcprules /var/qmail/control/tcp.smtp.cdb \
                    /var/qmail/control/tcp.smtp.tmp \
                    < /var/qmail/control/tcp.smtp'
```

To regenerate from env vars, remove the CDB files and restart:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    rm /var/qmail/control/tcp.smtp.cdb \
       /var/qmail/control/tcp.submission.cdb \
       /var/qmail/control/tcp.smtps.cdb
docker compose -f docker/docker-compose.yml restart qmail
```

---

## IPv6 / Dual-stack

```yaml
environment:
  QMAIL_DUALSTACK: 1
```

Requires IPv6 enabled in Docker (`/etc/docker/daemon.json`):

```json
{ "ipv6": true, "fixed-cidr-v6": "fd00::/80" }
```

---

## Queue management

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/qmail-qstat

docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/qmail-qread
```
