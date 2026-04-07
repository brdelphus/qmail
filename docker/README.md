# qmail Docker

Containerised build of [sagredo-dev/qmail](https://github.com/sagredo-dev/qmail) —
a heavily patched netqmail-1.06 with TLS, DKIM, SPF, SRS, SMTP AUTH, chkuser,
SURBL and more — running under **runit** on **Debian bookworm-slim**.

---

## Build chain

The compilation order is strictly enforced because each step depends on the
previous one being installed:

```
libsrs2 → ucspi-ssl → netqmail → vpopmail → patched qmail → ezmlm-idx → qmailadmin
```

| Step | Why it must come first |
|---|---|
| **libsrs2** | qmail links against it at compile time (`conf-ld: -L/usr/local/lib`) |
| **ucspi-ssl** | `sslserver` binary needed at runtime for SMTPS/POP3S |
| **netqmail** | `make setup` creates `/var/qmail` with correct layout and ownership before vpopmail's `configure` runs |
| **vpopmail** | `chkuser.c` includes `vpopmail.h`/`vauth.h` and `qmail-smtpd` links against `/home/vpopmail/etc/lib_deps` |
| **patched qmail** | overwrites netqmail binaries, keeping the directory structure intact |
| **ezmlm-idx** | mailing list manager, used by qmailadmin |
| **qmailadmin** | web interface, requires vpopmail and ezmlm-idx |

---

## Quick start

```sh
# 1. Clone and enter the repo
git clone https://github.com/brdelphus/qmail
cd qmail

# 2. Edit docker/docker-compose.yml — set QMAIL_ME and QMAIL_DOMAIN
#    QMAIL_ME:     FQDN of this mail server  (e.g. mail.example.com)
#    QMAIL_DOMAIN: primary virtual domain    (e.g. example.com)

# 3. Build and start
docker compose -f docker/docker-compose.yml build
docker compose -f docker/docker-compose.yml up -d

# 4. Follow startup logs
docker compose -f docker/docker-compose.yml logs -f
```

---

## vpopmail auth backend

vpopmail is compiled with a single auth backend selected at build time.
The default is **CDB** (file-based, no external database required).

| Backend | Build arg | Extra runtime dependency |
|---|---|---|
| `cdb` *(default)* | *(none)* | *(none)* |
| `mysql` | `VPOPMAIL_AUTH=mysql` | MySQL / MariaDB server |
| `pgsql` | `VPOPMAIL_AUTH=pgsql` | PostgreSQL server |
| `ldap` | `VPOPMAIL_AUTH=ldap` | LDAP server |
| `passwd` | `VPOPMAIL_AUTH=passwd` | *(none)* |

All client dev libraries (`libmysqlclient-dev`, `libpq-dev`, `libldap-dev`) are
installed in the builder stage so you can switch backends without modifying the
Dockerfile — just rebuild with a different arg:

```sh
docker compose -f docker/docker-compose.yml build \
    --build-arg VPOPMAIL_AUTH=mysql
```

---

## Persistent volume

All mutable data lives under a **single named volume** (`maildata`) mounted at
`/srv/mail`. On first run the entrypoint seeds each subdirectory from the
image defaults and replaces the original paths with symlinks.

| Volume path | Symlinked from | Contents |
|---|---|---|
| `/srv/mail/qmail/control` | `/var/qmail/control` | Control files, TLS certs, tcprules CDBs |
| `/srv/mail/qmail/queue` | `/var/qmail/queue` | Mail queue — must be synchronous FS |
| `/srv/mail/vpopmail/domains` | `/home/vpopmail/domains` | Virtual domain mailboxes |
| `/srv/mail/vpopmail/etc` | `/home/vpopmail/etc` | vpopmail config, DB connection strings |

### Backup

```sh
docker run --rm \
    -v maildata:/srv/mail \
    -v $(pwd):/backup \
    debian:bookworm-slim \
    tar czf /backup/maildata-$(date +%F).tar.gz /srv/mail
```

### Restore

```sh
docker run --rm \
    -v maildata:/srv/mail \
    -v $(pwd):/backup \
    debian:bookworm-slim \
    tar xzf /backup/maildata-<date>.tar.gz -C /
```

---

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `QMAIL_ME` | yes | — | FQDN of this server (`mail.example.com`) |
| `QMAIL_DOMAIN` | no | derived from `QMAIL_ME` | Primary virtual domain, created in vpopmail on first run |
| `QMAIL_SOFTLIMIT` | no | `64000000` | Memory limit (bytes) per SMTP process |
| `QMAIL_CONCURRENCY_INCOMING` | no | `20` | Max simultaneous inbound SMTP connections |
| `QMAIL_CONCURRENCY_REMOTE` | no | `20` | Max simultaneous outbound deliveries |
| `QMAIL_CONCURRENCY_LOCAL` | no | `10` | Max simultaneous local deliveries |
| `QMAIL_SPFBEHAVIOR` | no | `3` | SPF check behavior (0=off, 3=reject fail, see docs) |
| `QMAIL_GREETDELAY` | no | `5` | Seconds to delay SMTP greeting (anti-spam) |
| `QMAIL_SURBL` | no | `0` | Enable SURBL URI filtering (0=off, 1=on) |
| `QMAIL_TLS_CERT` | no | — | Path to TLS certificate PEM (full chain) |
| `QMAIL_TLS_KEY` | no | — | Path to TLS private key PEM |
| `QMAIL_DH_BITS` | no | `2048` | DH parameter bit size (`2048` or `4096`) |
| `QMAIL_RELAY_NETS` | no | — | Comma-separated IPs/prefixes trusted to relay on port 25 (e.g. `"192.168.1.,10.0.0.2"`). Loopback is always trusted. |
| `QMAIL_CHKUSER_WRONGRCPTLIMIT` | no | `3` | Max invalid recipients before disconnect, applied to all SMTP ports |
| `VQADMIN_USER` | no | `admin` | vqadmin HTTP auth username |
| `VQADMIN_PASS` | no | auto-generated | vqadmin HTTP auth password |

---

## Exposed ports

| Port | Protocol | Service |
|---|---|---|
| `25` | SMTP | Inbound mail |
| `80` | HTTP | qmailadmin web interface |
| `110` | POP3 | Mail retrieval |
| `143` | IMAP | Mail retrieval (Dovecot) |
| `465` | SMTPS | SMTP over TLS |
| `587` | Submission | Authenticated outbound (SMTPAUTH required) |
| `993` | IMAPS | IMAP over TLS (Dovecot) |
| `995` | POP3S | POP3 over TLS |

---

## Runit services

The container runs six supervised services under `runsvdir`:

| Service | Port | Notes |
|---|---|---|
| `qmail-smtpd` | 25 | `chkuser`, SPF, SURBL, DKIM verify, greet delay |
| `qmail-send` | — | Queue manager; enables DKIM signing if `control/filterargs` exists |
| `qmail-submission` | 587 | Auth required (`SMTPAUTH=!`), STARTTLS |
| `qmail-smtps` | 465 | Auth required, implicit TLS via `sslserver` |
| `dovecot` | 110 / 143 / 993 / 995 | POP3, IMAP, IMAPS, POP3S — Maildir via vpopmail domains, `vchkpw` auth. Pinned to 2.3.x (Dovecot 2.4 removed the `checkpassword` driver) |
| `lighttpd` | 80 | Web server for qmailadmin CGI interface |
| `vusaged` | — | vpopmail quota usage cache daemon — reduces filesystem `stat()` calls on delivery |

Logs are written via `svlogd` to `/var/log/qmail/<service>/`.

### Check service status

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    sv status /etc/service/*
```

---

## TLS certificates

Both qmail (`sslserver`) and Dovecot read a single combined PEM file at
`/var/qmail/control/servercert.pem` (certificate block first, then private key).
DH parameters are stored at `/var/qmail/control/dh4096.pem`.

The entrypoint resolves the cert on every first-run using this priority:

| Priority | Condition | Result |
|---|---|---|
| 1 | `QMAIL_TLS_CERT` + `QMAIL_TLS_KEY` set | Combines the two files into `servercert.pem` |
| 2 | `servercert.pem` already exists in volume | Used as-is (e.g. placed there manually) |
| 3 | Neither | Self-signed cert generated for `QMAIL_ME` |

### Using Let's Encrypt

Mount the certbot volume and set the env vars in `docker-compose.yml`:

```yaml
environment:
  QMAIL_TLS_CERT: /etc/letsencrypt/live/mail.example.com/fullchain.pem
  QMAIL_TLS_KEY:  /etc/letsencrypt/live/mail.example.com/privkey.pem
volumes:
  - /etc/letsencrypt:/etc/letsencrypt:ro
  - maildata:/srv/mail
```

On cert renewal, restart the container to re-combine the PEM:

```sh
docker compose -f docker/docker-compose.yml restart
```

### Manual cert replacement

```sh
cat fullchain.pem privkey.pem > /var/lib/docker/volumes/maildata/_data/qmail/control/servercert.pem
chmod 600 /var/lib/docker/volumes/maildata/_data/qmail/control/servercert.pem
docker compose -f docker/docker-compose.yml restart
```

### SNI — multiple domains

SNI (Server Name Indication) lets the server present different certificates
depending on which hostname the client requests during the TLS handshake.
Both qmail and Dovecot support it.

Set `QMAIL_SNI_CERTS` to a semicolon-separated list of `domain:cert:key` triplets:

```yaml
environment:
  QMAIL_SNI_CERTS: "mail2.example.org:/etc/letsencrypt/live/mail2.example.org/fullchain.pem:/etc/letsencrypt/live/mail2.example.org/privkey.pem;mail3.example.net:/etc/letsencrypt/live/mail3.example.net/fullchain.pem:/etc/letsencrypt/live/mail3.example.net/privkey.pem"
volumes:
  - /etc/letsencrypt:/etc/letsencrypt:ro
  - maildata:/srv/mail
```

On every startup the entrypoint:
- Combines each cert+key into `control/servercerts/<domain>/servercert.pem` (qmail SNI)
- Generates `control/dovecot-sni.conf` with `local_name` blocks (Dovecot SNI)

The primary domain cert (`QMAIL_TLS_CERT` / `QMAIL_TLS_KEY`) remains the fallback
for clients that don't send SNI.

Verify with:

```sh
openssl s_client -starttls smtp -connect mail.example.com:587 -servername mail2.example.org
```

### DH parameters

Generated once at first run using 2048-bit by default. Increase to 4096-bit:

```yaml
environment:
  QMAIL_DH_BITS: 4096
```

To regenerate, delete `dh4096.pem` from the volume and restart.

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

- **Signing**: Outbound mail is signed via `spawn-filter` using keys in `/var/qmail/control/domainkeys/<domain>/default`
- **Verification**: Inbound mail is verified via `qmail-dkim` with results added to headers

### View DKIM DNS record

After first run, the DNS TXT record is saved to:
```
/srv/mail/qmail/control/domainkeys/<domain>.dns.txt
```

Add this record to your DNS as `default._domainkey.<domain>`.

### Generate key for additional domain

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/dknewkey -d newdomain.com -t rsa -b 2048 default
```

### filterargs configuration

Edit `/srv/mail/qmail/control/filterargs` to customize DKIM signing behavior.

---

## DNS blocklists (DNSBL/RBL)

A template `dnsbllist` file is created at `/srv/mail/qmail/control/dnsbllist`.
Uncomment and customize the blocklists as needed:

```sh
# Edit the file
docker compose -f docker/docker-compose.yml exec qmail \
    vi /var/qmail/control/dnsbllist
```

Format: one blocklist per line, prefix with `-` for 553 reject (vs 451 defer).

---

## qmailadmin web interface

The container includes [qmailadmin](https://github.com/sagredo-dev/qmailadmin), a
web-based administration interface for managing vpopmail domains and users.

### Access

Open `http://<server-ip>/` in a browser. The root URL redirects to qmailadmin.

### Login

- **Domain**: your virtual domain (e.g. `example.com`)
- **User**: `postmaster` (or any admin user)
- **Password**: the postmaster password set via `vadduser`

### Features

- Add/edit/delete users and aliases
- Manage autoresponders (vacation messages)
- Configure mail forwarding
- Manage mailing lists (ezmlm-idx)
- Set mailbox quotas

---

## vqadmin (system admin)

[vqadmin](https://github.com/sagredo-dev/vqadmin) is a system-level admin interface
for managing vpopmail at the domain level (add/remove domains, etc.).

### Access

Open `http://<server-ip>/cgi-bin/vqadmin/vqadmin.cgi`

### Authentication

vqadmin requires HTTP basic auth. Credentials are set on first run:

- **User**: `admin` (or set via `VQADMIN_USER` env var)
- **Password**: auto-generated (check container logs) or set via `VQADMIN_PASS` env var

To change the password later:
```sh
docker compose -f docker/docker-compose.yml exec qmail \
    htpasswd /var/qmail/control/vqadmin.htpasswd admin
```

### Features

- Add/remove virtual domains
- View domain statistics
- Manage domain limits

---

## Sieve filtering and ManageSieve

[Pigeonhole Sieve](https://pigeonhole.dovecot.org/) is installed via
`dovecot-sieve` and `dovecot-managesieved` (Debian packages, pre-compiled
against Dovecot 2.3.19.1 — no source build needed).

### Delivery pipeline

Mail is delivered via **Dovecot-LDA** instead of `vdelivermail`, enabling Sieve
to filter every inbound message before it hits the Maildir:

```
qmail-local → .qmail-default → dovecot-lda → Sieve → Maildir
```

The `.qmail-default` in each domain directory is set on first run:
```
|/usr/lib/dovecot/dovecot-lda -d "$EXT@$HOST" -f "$SENDER"
```

### ManageSieve (port 4190)

Mail clients (Thunderbird, Roundcube, etc.) connect to port 4190 to upload and
manage Sieve scripts. Authentication uses the same credentials as IMAP/POP3.

Per-user scripts are stored at:
- `~/sieve/` — script collection (managed via ManageSieve)
- `~/.dovecot.sieve` — active script symlink (points into `~/sieve/`)

Where `~` expands to `/home/vpopmail/domains/<domain>/<user>`.

### Global Sieve scripts

Server-wide rules (spam-to-Junk, virus tagging, etc.) live in the volume and
run for every user before or after their personal script:

| Directory | Runs |
|---|---|
| `/srv/mail/qmail/control/sieve/before.d/` | Before user's script (alphabetical) |
| `/srv/mail/qmail/control/sieve/after.d/` | After user's script (alphabetical) |

After adding or changing a global script, compile it:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    sievec /var/qmail/control/sieve/before.d/10-spam.sieve
```

Example spam-to-Junk global script (`before.d/10-spam.sieve`):

```sieve
require ["fileinto", "mailbox"];
if header :contains "X-Spam-Flag" "YES" {
    fileinto :create "Junk";
    stop;
}
```

### Adding Sieve to an existing domain

If the container was started before Sieve support was added, update the
domain's delivery command manually:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    sh -c 'printf "|/usr/lib/dovecot/dovecot-lda -d \"\$EXT@\$HOST\" -f \"\$SENDER\"\n" \
        > /home/vpopmail/domains/example.com/.qmail-default && \
        chown vpopmail:vchkpw /home/vpopmail/domains/example.com/.qmail-default'
```

---

## tcprules (relay and recipient policy)

Three CDB files control TCP access policy, compiled from plain-text source files
by `tcprules` on first run. They live in `/srv/mail/qmail/control/`.

| File | Port | Purpose |
|---|---|---|
| `tcp.smtp` | 25 | Inbound relay — trusted IPs get `RELAYCLIENT=""`, everyone else can receive mail but not relay |
| `tcp.submission` | 587 | Authenticated submission — all connections allowed, relay gated by `SMTPAUTH` |
| `tcp.smtps` | 465 | Same as submission over implicit TLS |

The `tcp.smtp` file is generated from the env vars at first run:

```
0.0.0.0:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"   # always trusted
127.:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"        # always trusted
192.168.1.:allow,RELAYCLIENT="",SMTPD_GREETDELAY="0"  # from QMAIL_RELAY_NETS
:allow,CHKUSER_WRONGRCPTLIMIT="3"                      # catch-all
```

### Modifying rules on a live container

The CDB files are only seeded once (on first run). To update them on an existing
volume, edit the source file and recompile:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    sh -c 'vi /var/qmail/control/tcp.smtp && \
           tcprules /var/qmail/control/tcp.smtp.cdb \
                    /var/qmail/control/tcp.smtp.tmp \
                    < /var/qmail/control/tcp.smtp'
```

To force a full regeneration from env vars, remove the CDB files and restart:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    rm /var/qmail/control/tcp.smtp.cdb \
       /var/qmail/control/tcp.submission.cdb \
       /var/qmail/control/tcp.smtps.cdb
docker compose -f docker/docker-compose.yml restart
```

---

## IPv6 / Dual-stack

IPv6 support is provided by [ucspi-tcp6](https://www.fehcom.de/ipnet/ucspi-tcp6.html)
(Erwin Hoffmann), compiled in the builder stage. It replaces Debian's `ucspi-tcp`
as the network listener for qmail's SMTP ports.

By default the container binds on `0.0.0.0` (IPv4 only). Enable dual-stack to
bind on `::` and accept both IPv4 and IPv6 connections:

```yaml
environment:
  QMAIL_DUALSTACK: 1
```

Requires IPv6 to be enabled in Docker:

```json
# /etc/docker/daemon.json
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80"
}
```

And in `docker-compose.yml`:

```yaml
networks:
  default:
    enable_ipv6: true
```

### What changes with dualstack enabled

| Component | IPv4 only (`0`) | Dual-stack (`::`) |
|---|---|---|
| Port 25 (SMTP) | `0.0.0.0` | `::` |
| Port 587 (Submission) | `0.0.0.0` | `::` |
| Port 465 (SMTPS) | `0.0.0.0` | `::` |
| `tcp.smtp` loopback | `127.` | `127.` + `::1` |
| Dovecot (IMAP/POP3) | IPv6 always on | IPv6 always on |

Dovecot handles its own networking and supports IPv6 natively regardless of this
setting.

### Relay nets with IPv6

If you have IPv6 trusted networks, add them to `QMAIL_RELAY_NETS`:

```yaml
QMAIL_RELAY_NETS: "192.168.1.,2001:db8::"
```

---

## Greylisting

[jgreylist](https://qmail.jms1.net/scripts/jgreylist.shtml) by John Simpson
provides file-based greylisting — no database required. On first contact from
an unknown sender, qmail temporarily rejects the message (451). Legitimate MTAs
retry and are whitelisted; spam bots typically don't.

jgreylist wraps `qmail-smtpd` in the port 25 run script and is transparent to
submission (587) and SMTPS (465) since authenticated users bypass it.

### Enable

```yaml
environment:
  QMAIL_GREYLISTING: 1
```

State files are stored in `/srv/mail/jgreylist` (persisted in the volume).

### How it works

```
tcpserver → jgreylist → qmail-smtpd
              ↓
         First contact: 451 temporary reject (greylisted)
         Retry contact: pass through to qmail-smtpd
```

### Cleanup

Expired greylist entries should be purged periodically. Run from outside the
container (cron, Kubernetes CronJob, etc.):

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/jgreylist-clean
```

### Persistent volume path

| Volume path | Symlinked from | Contents |
|---|---|---|
| `/srv/mail/jgreylist` | `/var/qmail/jgreylist` | Greylist state files |

---

## Mail tapping (qmail-taps-extended)

qmail-taps-extended copies matching messages to a destination address as they
flow through the queue. Useful for archiving, compliance, or auditing.

### Configuration

Set `QMAIL_TAPS` to a semicolon-separated list of rules at first run:

```yaml
environment:
  QMAIL_TAPS: "F:.*@example.com:archive@example.com;T:.*@partner.com:audit@example.com"
```

Each rule uses the format `TYPE:REGEX:DESTINATION`:

| Field | Values | Description |
|---|---|---|
| `TYPE` | `F` | Match on **From** address |
| | `T` | Match on **To** address |
| | `A` | Match **all** mail (original Inter7 behavior) |
| `REGEX` | e.g. `.*@example.com` | Regular expression applied to the address |
| `DESTINATION` | e.g. `archive@example.com` | Address that receives the copy |

The rules are written to `/var/qmail/control/taps`. If `QMAIL_TAPS` is not set,
an empty `taps` file is created (tapping disabled).

### Live editing

Unlike CDB-based control files, `taps` is plain text and **takes effect
immediately** without a restart:

```sh
docker compose -f docker/docker-compose.yml exec qmail \
    vi /var/qmail/control/taps
```

### Examples

```
# Archive all outbound mail from your domain
F:.*@example.com:archive@example.com

# Copy all inbound mail to an audit address
T:.*@example.com:audit@example.com

# Tap a specific user
T:ceo@example.com:legal@example.com

# Catch-all tap for a domain
A:.*@example.com:mirror@example.com
```

---

## Queue management

```sh
# Queue stats
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/qmail-qstat

# Read queue
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/qmail-qread
```
