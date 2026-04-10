# qmail SMTP triggers — reference & test notes

All triggers apply to the three SMTP listeners unless otherwise noted.

| Port | Service | Auth | TLS |
|------|---------|------|-----|
| 25 | MX inbound | none | STARTTLS optional |
| 465 | SMTPS submission | required | implicit (sslserver) |
| 587 | Submission | required | STARTTLS required |

---

## Trigger map

How every qmail-smtpd feature is activated. Three mechanisms:
- **control/** — file read by the run script at container start (volume-persisted, global)
- **env** — variable exported by the run script (hardcoded or derived from a control file)
- **tcp.cdb** — per-connection variable injected by tcpserver from the compiled access rules

### All three ports (25 / 465 / 587)

| Feature | Mechanism | trigger | What it does |
|---------|-----------|---------|--------------|
| Concurrency | control/ | `control/concurrencyincoming` | Max simultaneous SMTP connections (`tcpserver -c`) |
| Memory limit | control/ | `control/softlimit` | `RLIMIT_AS` per smtpd child (`chpst -m`) |
| Hostname | control/ | `control/me` | Server name in banner and `tcpserver -l` |
| Dual-stack | control/ | `control/dualstack` | Binds `::` (IPv4+IPv6) when `1`, `0.0.0.0` otherwise |
| Greet delay | control/ → env | `control/greetdelay` → `SMTPD_GREETDELAY` | Seconds to wait before the `220` banner (default 5) |
| Pre-greet drop | env | `DROP_PRE_GREET=1` | Drops clients that send data before the banner |
| SURBL | control/ → env | `control/surbl` → `SURBL` | Enable URL blocklist scanning during DATA (default 0) |
| DKIM verify | control/ → env | `control/dkimverify` → `DKIMVERIFY` | Inbound DKIM verification flags (empty = off) |
| DKIM sign queue | env | `QMAILQUEUE=qmail-dkim` | Routes all mail through qmail-dkim for signing/verify |
| Skip DKIM for relays | env | `RELAYCLIENT_NODKIMVERIFY=1` | Authenticated relay clients skip DKIM re-verification |
| Simscan AV/spam | env | `DKIMQUEUE=simscan` (when `SIMSCAN_ENABLE`) | After DKIM verify, pass to simscan for AV + spam |
| SPP plugins | control/ → env | `control/smtpplugins` + `plugins/` dir → `ENABLE_SPP=1` | Enables qmail-spp plugin system (greylisting, SPF, etc.) |
| User validation | env | `CHKUSER_START=ALWAYS` | Validates sender domain MX and recipient in vpopmail DB |
| Auth from-match | env | `FORCEAUTHMAILFROM=1` | MAIL FROM must match the authenticated user |
| Wrong rcpt limit | tcp.cdb | `CHKUSER_WRONGRCPTLIMIT="3"` (catch-all) | Disconnects after N invalid RCPT TOs |

### Port 25 only (MX inbound)

| Feature | Mechanism | Trigger | What it does |
|---------|-----------|---------|--------------|
| Relay permission | tcp.cdb | `RELAYCLIENT=""` for loopback + RELAY_NETS | Grants relay; skips simscan spam scan |
| Greet delay bypass | tcp.cdb | `SMTPD_GREETDELAY="0"` for relay IPs | Trusted senders skip the greet delay |
| jgreylist | control/ | `control/jgreylist=1` | Wraps smtpd with file-based triplet greylisting binary |
| jgreylist dirs | env | `JGREYLIST_DIR`, `JGREYLIST_LOG_SMTP=1` | State directory and logging for jgreylist |
| SPP greylisting | control/ → env | `control/greylisting` → `GREYLISTING=""` + `GLCONFIGFILE` | MySQL-backed triplet greylisting via SPP plugin |

### Ports 465 + 587 only (submission)

| Feature | Mechanism | Trigger | What it does |
|---------|-----------|---------|--------------|
| Auth required | env | `SMTPAUTH="!"` | Clients must authenticate before MAIL FROM |
| Rate limiting | env | `RCPTCHECK=rcptcheck-overlimit`, `OVERLIMITDIR`, `LIMITSCONTROLFILE` | Rejects when auth user/IP exceeds `control/relaylimits` count |

### Port 465 only (SMTPS)

| Feature | Mechanism | Trigger | What it does |
|---------|-----------|---------|--------------|
| TLS certificate | control/ → env | `control/servercert.pem` → `CERTFILE`/`KEYFILE` | Certificate for sslserver's implicit TLS |
| DH params | control/ → env | `control/dh4096.pem` → `DHFILE` | Diffie-Hellman params for TLS key exchange |
| Disable STARTTLS | env | `DISABLETLS=1` | Stops smtpd advertising STARTTLS (already encrypted by sslserver) |
| No TLS-for-auth gate | env | `FORCETLS=0` | Lets smtpd offer AUTH without its own TLS context |

### Port 587 only (submission STARTTLS)

| Feature | Mechanism | Trigger | What it does |
|---------|-----------|---------|--------------|
| Require STARTTLS | env | `FORCETLS=1` | Client must issue STARTTLS before AUTH is offered |

### qmail-send only

| Feature | Mechanism | Trigger | What it does |
|---------|-----------|---------|--------------|
| Local delivery | control/ | `control/defaultdelivery` | qmail-start delivery program (default: `lmtp-deliver`) |
| DKIM signing | control/ | `control/filterargs` + `bin/spawn-filter` → `QMAILREMOTE=spawn-filter` | Signs outbound mail using keys in `control/domainkeys/` |

---

### Single-mechanism features (no override path)

| Feature | Only mechanism | Gap |
|---------|---------------|-----|
| SURBL | control/ file | No per-IP tcp.cdb override |
| DKIM verify | control/ file | No per-IP tcp.cdb override |
| SPF behavior | control/ file (`control/spfbehavior`) | No per-IP tcp.cdb override |
| Rate limiting | env (hardcoded paths) | No control/ file toggle; no per-IP off switch |
| jgreylist | control/ file | No per-IP override (plugin skips RELAYCLIENT internally) |
| SPP greylisting | control/ file (presence check) | No per-IP on/off; plugin skips RELAYCLIENT internally |
| DKIM signing (send) | control/ files | No env var runtime toggle |
| Wrong rcpt limit | tcp.cdb only | Default "3" baked into entrypoint; no `control/chkuser_wrongrcptlimit` |

`SMTPD_GREETDELAY` is the only feature with **both** a global control file and a per-IP tcp.cdb override — intentional, so trusted senders bypass the delay.

---

## Connection-level triggers

### Greetdelay + DROP_PRE_GREET

| Control | Value | Env var |
|---------|-------|---------|
| `control/greetdelay` | `5` (seconds) | `SMTPD_GREETDELAY` |
| — | — | `DROP_PRE_GREET=1` |

qmail-smtpd waits `greetdelay` seconds before sending the `220` banner.
Any client that sends data before the banner is dropped with:

```
554 SMTP protocol violation
```

**Purpose:** kills spam bots that pipeline before greeting (most do).

**Test:**
```sh
# No sleep — fires immediately
printf 'EHLO example.com\r\n' | nc -q 2 localhost 25
# → 554 SMTP protocol violation

# With sleep > greetdelay — passes
(sleep 6; printf 'EHLO example.com\r\n') | nc -q 2 localhost 25
# → 220 mail.example.com ESMTP
```

**Tested:** ✓ `554 SMTP protocol violation` on immediate EHLO

---

### BRTLIMIT — bad RCPT TO limit

| Control | Value |
|---------|-------|
| `control/brtlimit` | `2` |

Disconnects after N consecutive invalid RCPT TO addresses with:

```
421 too many invalid addresses
```

Note: fires **before** `CHKUSER_WRONGRCPTLIMIT` (which is set to 3).
To test CHKUSER limit independently, set `brtlimit` higher than
`CHKUSER_WRONGRCPTLIMIT` or use a separate connection.

**Test:**
```sh
(sleep 6; printf 'EHLO mail.gmail.com\r\nMAIL FROM:<s@gmail.com>\r\nRCPT TO:<noone1@example.com>\r\nRCPT TO:<noone2@example.com>\r\n') \
  | nc -q 3 localhost 25
# → 550 noone1@example.com (#5.1.1)
# → 421 too many invalid addresses (after 2nd bad RCPT)
```

**Tested:** ✓ `421 too many invalid addresses` after 2nd bad RCPT

---

### MAXRCPT

| Control | Value |
|---------|-------|
| `control/maxrcpt` | `100` |

Hard limit on accepted RCPT TOs per message. After N accepted recipients,
further RCPT TOs get `452 too many recipients`.

---

### Concurrency

| Control | Value |
|---------|-------|
| `control/concurrencyincoming` | `200` |
| `control/softlimit` | `64000000` (64 MB RLIMIT_AS per child) |

`chpst -m 64000000` sets the virtual address space limit for qmail-smtpd
and all its children (simscan, rspamd-spamc, clamdscan). Note: `rspamc`
fails under this limit (libicudata.so.72 ~30 MB mmap); `rspamd-spamc`
therefore uses `curl` instead.

---

## Authentication triggers (ports 465 / 587)

### SMTPAUTH

| Env var | Value |
|---------|-------|
| `SMTPAUTH` | `!` (required) |

`!` = AUTH is required before MAIL FROM. Unauthenticated clients on
submission ports are rejected.

### FORCETLS (port 587)

| Env var | Value |
|---------|-------|
| `FORCETLS` | `1` |

Port 587 requires STARTTLS before AUTH. Clients that attempt AUTH on a
plain connection are rejected.

Port 465 uses `DISABLETLS=1` + `FORCETLS=0` because the connection is
already encrypted by `sslserver` before smtpd starts.

### FORCEAUTHMAILFROM

| Env var | Value |
|---------|-------|
| `FORCEAUTHMAILFROM` | `1` |

Requires the `MAIL FROM` envelope sender to match the authenticated
username. Prevents auth users from relaying as another identity.

---

## Recipient validation — CHKUSER

| Env var | Value |
|---------|-------|
| `CHKUSER_START` | `ALWAYS` |

CHKUSER validates both the sender domain (MX lookup) and the recipient
against the vpopmail/MariaDB user database on all three ports.

| Code | Condition |
|------|-----------|
| `550 5.1.1` | recipient not found |
| `550 5.1.8` | sender domain has no valid MX |
| `421` | bad RCPT limit reached (`brtlimit`) |

**Tested:** ✓ `550 5.1.8 sorry, can't find a valid MX for sender domain`

---

## Rate limiting — rcptcheck-overlimit (ports 465 / 587 only)

| Control | Format | Example |
|---------|--------|---------|
| `control/relaylimits` | `[user@domain\|domain\|IP\|]:N` | `:1000` |

After an authenticated user/IP sends N+1 messages (the check is `>` not
`>=`), the N+2nd RCPT TO is rejected with:

```
421 you have exceeded your messaging limits
```

Counter files live in `/var/qmail/overlimit/`. One file per
`user@domain` (or IP); each successful RCPT TO appends one byte.
Reset daily: `rm -f /var/qmail/overlimit/*`

Local domains (`control/rcpthosts`) are excluded from the count — only
external recipients count toward the limit.

**Test (limit = 1000, so use a low custom limit for manual test):**
```sh
# Set a low limit for testing
echo ":2" > /var/qmail/control/relaylimits
# Then send 4 mails — 4th RCPT TO to an external domain is rejected
```

**Tested:** ✓ `421 you have exceeded your messaging limits` on 4th external relay

---

## SPF

| Control | Value | Behaviour |
|---------|-------|-----------|
| `control/spfbehavior` | `3` | reject on SPF fail (`550`) |

`spfbehavior` values:
- `0` = disabled
- `1` = `Received-SPF` header only
- `2` = reject on SPF fail (temp: `451`)
- `3` = reject on SPF fail (perm: `550`)

Note: requires real DNS in test environment. Skipped in LAN tests.

---

## DNSBL

| Control | Format |
|---------|--------|
| `control/dnsbllist` | one RBL zone per line; prefix `-` for `553` reject |

```
# Example entries (all commented out by default)
#-zen.spamhaus.org
#-b.barracudacentral.org
#-bl.spamcop.net
```

When a listed RBL zone is queried and the client IP is listed, qmail-smtpd
returns `553 sorry, your IP is blocked` (with `-` prefix) or `451` (defer).

**Not tested** (requires controlling client IP / DNS in test env).

---

## SURBL — URL blocklist

| Control | Value | Env var |
|---------|-------|---------|
| `control/surbl` | `0` (disabled) | `SURBL` |

Set `control/surbl=1` to enable. qmail-smtpd extracts URLs from the message
body during DATA and queries SURBL/URIBL. Listed domains → message rejected.

**Not tested** (requires DNS access to SURBL zones).

---

## DKIM (verify inbound, sign outbound)

| Env var | Value | Effect |
|---------|-------|--------|
| `QMAILQUEUE` | `qmail-dkim` | all mail goes through DKIM verify |
| `DKIMVERIFY` | `FGHKLMNOQRTVWp` | flags for verification behavior |
| `DKIMQUEUE` | `simscan` | after verify, pass to simscan |
| `RELAYCLIENT_NODKIMVERIFY` | `1` | skip verify for authenticated relay clients |

DKIM signing: inbound mail (port 25) is verified; outbound (ports 465/587)
is signed using keys in `control/domainkeys/`.

The `DKIM-Status:` header is added to every delivered message:
```
DKIM-Status: no signature (no signatures)
DKIM-Status: pass
DKIM-Status: fail (bad signature)
```

**Not tested** in this session (requires a DKIM-signed sender).

---

## Simscan — AV + spam scanning queue wrapper

Delivery chain:
```
qmail-smtpd
  └── QMAILQUEUE=qmail-dkim       (DKIM verify)
        └── DKIMQUEUE=simscan     (only when SIMSCAN_ENABLE=true)
              ├── clamdscan        (ClamAV via INSTREAM TCP)
              └── rspamd-spamc     (rspamd HTTP API via curl)
                    └── qmail-queue
```

Simscan skips spam scanning when `RELAYCLIENT` is set (authenticated
submission on ports 465/587) — only inbound port 25 mail is scanned.

| Env var | Default | Effect |
|---------|---------|--------|
| `SIMSCAN_ENABLE` | `true` | master toggle |
| `SIMSCAN_CLAM` | `no` | ClamAV (rspamd owns AV via antivirus module) |
| `SIMSCAN_SPAM` | `yes` | rspamd spam scanning |
| `SIMSCAN_SPAM_HITS` | `9.0` | score threshold for rejection |
| `SIMSCAN_SIZE_LIMIT` | `20000000` | max bytes to scan |
| `SIMSCAN_DEBUG` | `0` | debug verbosity 0–4 |
| `RSPAMD_TAG_ONLY` | `false` | when true: headers added but never reject |

**simcontrol** (`control/simcontrol` → compiled to `simcontrol.cdb` by `simscanmk`):
```
# catch-all rule
:clam=no,spam=yes,spam_hits=9.0,size_limit=20000000
```

Log format:
```
simscan:[qp]:CLEAN (score/required/hits):time:subject:ip:sender:rcpt
simscan:[qp]:SPAM REJECT (score/required/hits):…
```

---

## rspamd-spamc — rspamd HTTP wrapper

| Env var | Default |
|---------|---------|
| `RSPAMD_HOST` | `rspamd` |
| `RSPAMD_PORT` | `11333` |
| `RSPAMD_TAG_ONLY` | `false` |

Uses `curl` (not `rspamc`) to avoid libicudata.so.72 mmap failure under
the 64 MB `chpst -m` RLIMIT_AS limit.

Queries `POST http://rspamd:11333/checkv2` with the raw message.
Parses JSON response fields: `score`, `required_score`, `action`.

| rspamd action | X-Spam-Flag | simscan exit | result |
|---------------|-------------|--------------|--------|
| `reject` | YES | 1 | message rejected |
| `add header` | YES | 0 | tagged, Sieve can act |
| `rewrite subject` | YES | 0 | tagged |
| anything else | NO | 0 | clean |
| rspamd unavailable | — | 0 | pass-through |

**Tested:** ✓ GTUBE → `554 Your email is considered spam (15.00 spam-hits)`

---

## Rspamd symbols (relevant to spam/AV)

| Symbol | Score | Trigger |
|--------|-------|---------|
| `GTUBE` | 15.0 | GTUBE test string in body |
| `TIKA_EXTRACTED` | 0.0 | Tika extracted text from PDF/DOCX |
| `OLETOOLS_MACRO_MRAPTOR` | 20.0 | VBA macro with auto-exec + write |
| `OLETOOLS_MACRO_SUSPICIOUS` | 20.0 | VBA stomping or suspicious flags |
| `OLETOOLS_FAIL` | — | olevba scan error |

---

## Greylisting

Two independent implementations available:

### jgreylist (file-based)

| Control | Default |
|---------|---------|
| `control/jgreylist` | `0` (disabled) |
| `JGREYLIST_DIR` | `/var/qmail/jgreylist` |

Set `control/jgreylist=1` to enable. Wraps qmail-smtpd as a pre-filter.
First delivery attempt from an unknown `(IP, sender, recipient)` triplet
gets a `451 Greylisted` temporary reject. Retry after ~5 minutes passes.

### qmail-spp MySQL greylisting (plugin)

| Control | Enabled by |
|---------|-----------|
| `ENABLE_SPP=1` | presence of `control/smtpplugins` + `plugins/` dir |
| `GREYLISTING=""` | presence of `control/greylisting` file |

MySQL-backed triplet state shared across all MX servers. Uses the
`greylisting` database on MariaDB. Works via qmail-spp plugin mechanism.

---

## tcp.smtp / tcp.smtps / tcp.submission — access rules

CDB files control per-IP access and relay:

| File | Port |
|------|------|
| `control/tcp.smtp.cdb` | 25 |
| `control/tcp.smtps.cdb` | 465 |
| `control/tcp.submission.cdb` | 587 |

Compiled from corresponding text files with `tcprules`. Lines set env
vars per connection:
```
127.0.0.1:allow,RELAYCLIENT=""
:allow
```

Setting `RELAYCLIENT=""` grants relay permission (and skips simscan spam
scanning for that connection).

---

## Quick-reference test commands

```sh
# Greetdelay — immediate EHLO → reject
printf 'EHLO example.com\r\n' | nc -q 2 localhost 25

# Inbound with greetdelay wait
(sleep 6; printf 'EHLO mail.gmail.com\r\nMAIL FROM:<s@gmail.com>\r\nRCPT TO:<testuser@example.com>\r\nDATA\r\n<body>\r\n.\r\nQUIT\r\n') | nc -q 5 localhost 25

# GTUBE spam rejection (port 25, inbound)
(sleep 6; printf 'EHLO mail.gmail.com\r\nMAIL FROM:<s@gmail.com>\r\nRCPT TO:<testuser@example.com>\r\nDATA\r\nFrom: s@gmail.com\r\nTo: testuser@example.com\r\nSubject: test\r\n\r\nXJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X\r\n.\r\nQUIT\r\n') | nc -q 5 localhost 25
# → 554 Your email is considered spam (15.00 spam-hits)

# BRTLIMIT — 2 bad RCPTs → disconnect
(sleep 6; printf 'EHLO mail.gmail.com\r\nMAIL FROM:<s@gmail.com>\r\nRCPT TO:<nobody1@example.com>\r\nRCPT TO:<nobody2@example.com>\r\n') | nc -q 3 localhost 25
# → 421 too many invalid addresses

# Authenticated relay (port 587, requires valid credentials)
# SMTPAUTH: credential format is base64("\0user@domain\0password")
# Rate limit test: send 4 mails to external domain, 4th is rejected
```
