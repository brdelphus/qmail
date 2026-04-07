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
| Variable | Required | Default | Description |
|---|---|---|---|
| `QMAIL_ME` | yes | — | FQDN of this server (`mail.example.com`) |
| `QMAIL_DOMAIN` | no | derived from `QMAIL_ME` | Primary virtual domain, created in vpopmail on first run |
| `QMAIL_SOFTLIMIT` | no | `64000000` | Memory limit (bytes) per SMTP process |
| `QMAIL_CONCURRENCY_INCOMING` | no | `20` | Max simultaneous inbound SMTP connections |
| `QMAIL_CONCURRENCY_REMOTE` | no | `20` | Max simultaneous outbound deliveries |
| `QMAIL_CONCURRENCY_LOCAL` | no | `10` | Max simultaneous local deliveries |
| `QMAIL_TLS_CERT` | no | — | Path to TLS certificate PEM (full chain). Must be accessible inside the container |
| `QMAIL_TLS_KEY` | no | — | Path to TLS private key PEM. Must be set together with `QMAIL_TLS_CERT` |
| `QMAIL_DH_BITS` | no | `2048` | DH parameter bit size (`2048` or `4096`) |

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
| `dovecot` | 110 / 143 / 993 / 995 | POP3, IMAP, IMAPS, POP3S — Maildir via vpopmail domains, `vchkpw` auth |
| `lighttpd` | 80 | Web server for qmailadmin CGI interface |

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

## Queue management

```sh
# Queue stats
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/qmail-qstat

# Read queue
docker compose -f docker/docker-compose.yml exec qmail \
    /var/qmail/bin/qmail-qread
```
