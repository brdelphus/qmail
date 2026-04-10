#!/usr/bin/env python3
"""
qmail domain management REST API.

Runs inside the qmail container with direct access to vpopmail CLI tools.

Endpoints
---------
GET    /domains                               list all domains
POST   /domains                               add domain (full setup)
GET    /domains/<domain>                      domain info + DNS records
DELETE /domains/<domain>                      delete domain
GET    /domains/<domain>/users                list users
POST   /domains/<domain>/users                add user
DELETE /domains/<domain>/users/<user>         delete user
PUT    /domains/<domain>/users/<user>/password change password

Authentication: Authorization: Bearer <QMAIL_API_KEY>
"""
import glob
import grp
import os
import pwd
import re
import subprocess
from functools import wraps
from flask import Flask, request, jsonify

app = Flask(__name__)

QMAILDIR = '/var/qmail'
VPOPMAIL = '/home/vpopmail'
CONTROL  = f'{QMAILDIR}/control'

_DOMAIN_RE = re.compile(r'^(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$')
_USER_RE   = re.compile(r'^[a-z0-9][a-z0-9._\-+]{0,63}$')


# ── Auth ──────────────────────────────────────────────────────────────────────

def _require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        key = os.environ.get('QMAIL_API_KEY', '').strip()
        if not key:
            return jsonify({'error': 'QMAIL_API_KEY not configured on server'}), 503
        if request.headers.get('Authorization', '') != f'Bearer {key}':
            return jsonify({'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return decorated


# ── Helpers ───────────────────────────────────────────────────────────────────

def _run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout.strip(), r.stderr.strip(), r.returncode


def _domains():
    return sorted(
        os.path.basename(p)
        for p in glob.glob(f'{VPOPMAIL}/domains/*')
        if os.path.isdir(p)
    )


def _rebuild_users():
    """Rebuild /var/qmail/users/assign and compile with qmail-newu."""
    try:
        uid = pwd.getpwnam('vpopmail').pw_uid
        gid = pwd.getpwnam('vpopmail').pw_gid
    except KeyError as e:
        return str(e)
    lines = []
    for d in sorted(glob.glob(f'{VPOPMAIL}/domains/*/')):
        dom = os.path.basename(d.rstrip('/'))
        lines.append(f'+{dom}-:{dom}:{uid}:{gid}:{d}:-::\n')
    lines.append('.\n')
    with open(f'{QMAILDIR}/users/assign', 'w') as fh:
        fh.writelines(lines)
    out, err, rc = _run([f'{QMAILDIR}/bin/qmail-newu'])
    if rc != 0:
        return f'qmail-newu: {err or out}'
    return None


def _dkim_setup(domain, key_type='rsa', key_bits=2048):
    """
    Generate DKIM key for domain if it does not exist.
    Returns (dns_record_str, error_str).
    dknewkey validates domain is in rcpthosts — call only after vadddomain.
    Key files: $CONTROL/domainkeys/<domain>/default     (private, 640 root:qmail)
               $CONTROL/domainkeys/<domain>/default.pub (DNS record, 644 root:qmail)
    """
    key_file = f'{CONTROL}/domainkeys/{domain}/default'
    pub_file = f'{CONTROL}/domainkeys/{domain}/default.pub'

    if not os.path.exists(key_file):
        cmd = [f'{QMAILDIR}/bin/dknewkey', '-d', domain, '-t', key_type]
        if key_type == 'rsa':
            cmd += ['-b', str(key_bits)]
        cmd.append('default')
        out, err, rc = _run(cmd)
        if rc != 0:
            return None, f'dknewkey: {err or out}'

    if os.path.exists(pub_file):
        return open(pub_file).read().strip(), None
    return None, 'key generated but default.pub not found'


def _dns_records(domain):
    """Assemble the DNS records a domain needs to function correctly."""
    records = {}
    try:
        me = open(f'{CONTROL}/me').read().strip()
        records['MX'] = {'host': '@', 'priority': 10, 'value': me}
    except OSError:
        pass
    records['SPF']   = {'host': '@',      'type': 'TXT', 'value': 'v=spf1 mx ~all'}
    records['DMARC'] = {'host': '_dmarc', 'type': 'TXT',
                        'value': f'v=DMARC1; p=none; rua=mailto:dmarc@{domain}'}
    pub = f'{CONTROL}/domainkeys/{domain}/default.pub'
    if os.path.exists(pub):
        records['DKIM'] = {
            'host': 'default._domainkey',
            'type': 'TXT',
            'record': open(pub).read().strip(),
        }
    return records


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route('/domains', methods=['GET'])
@_require_api_key
def list_domains():
    return jsonify({'domains': _domains()})


@app.route('/domains', methods=['POST'])
@_require_api_key
def add_domain():
    data     = request.get_json(force=True, silent=True) or {}
    domain   = data.get('domain', '').strip().lower()
    password = data.get('postmaster_password', '').strip()
    key_type = data.get('dkim_key_type', 'rsa').strip().lower()
    key_bits = data.get('dkim_key_bits', 2048)

    if not domain:
        return jsonify({'error': 'domain is required'}), 400
    if not _DOMAIN_RE.match(domain):
        return jsonify({'error': f'invalid domain: {domain}'}), 400
    if not password:
        return jsonify({'error': 'postmaster_password is required'}), 400
    if key_type not in ('rsa', 'ed25519'):
        return jsonify({'error': 'dkim_key_type must be rsa or ed25519'}), 400
    if key_type == 'rsa' and key_bits not in (1024, 2048, 4096):
        return jsonify({'error': 'dkim_key_bits must be 1024, 2048, or 4096'}), 400
    if domain in _domains():
        return jsonify({'error': f'{domain} already exists'}), 409

    # 1. Create vpopmail domain — also adds to rcpthosts / virtualdomains
    out, err, rc = _run([f'{VPOPMAIL}/bin/vadddomain', domain, password])
    if rc != 0:
        return jsonify({'error': f'vadddomain: {err or out}'}), 500

    # 2. Replace vdelivermail .qmail-default with LMTP delivery to Dovecot
    qd = f'{VPOPMAIL}/domains/{domain}/.qmail-default'
    with open(qd, 'w') as fh:
        fh.write('|/var/qmail/bin/lmtp-deliver\n')
    try:
        os.chown(qd, pwd.getpwnam('vpopmail').pw_uid, grp.getgrnam('vchkpw').gr_gid)
    except KeyError:
        pass

    # 3. Generate DKIM key (dknewkey checks rcpthosts — must come after vadddomain)
    dkim_rec, dkim_err = _dkim_setup(domain, key_type=key_type, key_bits=key_bits)

    # 4. Rebuild users/assign so qmail routes the new domain correctly
    err2 = _rebuild_users()
    if err2:
        return jsonify({'error': f'users/assign: {err2}', 'domain': domain}), 500

    resp = {
        'domain': domain,
        'postmaster': f'postmaster@{domain}',
        'dns_records': _dns_records(domain),
    }
    if dkim_err:
        resp['dkim_warning'] = dkim_err
    return jsonify(resp), 201


@app.route('/domains/<domain>', methods=['GET'])
@_require_api_key
def get_domain(domain):
    if domain not in _domains():
        return jsonify({'error': f'{domain} not found'}), 404
    return jsonify({'domain': domain, 'dns_records': _dns_records(domain)})


@app.route('/domains/<domain>', methods=['DELETE'])
@_require_api_key
def delete_domain(domain):
    if domain not in _domains():
        return jsonify({'error': f'{domain} not found'}), 404
    out, err, rc = _run([f'{VPOPMAIL}/bin/vdeldomain', domain])
    if rc != 0:
        return jsonify({'error': f'vdeldomain: {err or out}'}), 500
    _rebuild_users()
    return jsonify({'deleted': domain})


@app.route('/domains/<domain>/users', methods=['GET'])
@_require_api_key
def list_users(domain):
    if domain not in _domains():
        return jsonify({'error': f'{domain} not found'}), 404
    dom_dir = f'{VPOPMAIL}/domains/{domain}'
    users = sorted(
        e for e in os.listdir(dom_dir)
        if os.path.isdir(os.path.join(dom_dir, e)) and not e.startswith('.')
    )
    return jsonify({'domain': domain, 'users': users})


@app.route('/domains/<domain>/users', methods=['POST'])
@_require_api_key
def add_user(domain):
    if domain not in _domains():
        return jsonify({'error': f'{domain} not found'}), 404
    data     = request.get_json(force=True, silent=True) or {}
    user     = data.get('user', '').strip().lower()
    password = data.get('password', '').strip()
    if not user:
        return jsonify({'error': 'user is required'}), 400
    if not _USER_RE.match(user):
        return jsonify({'error': f'invalid user: {user}'}), 400
    if not password:
        return jsonify({'error': 'password is required'}), 400
    out, err, rc = _run([f'{VPOPMAIL}/bin/vadduser', f'{user}@{domain}', password])
    if rc != 0:
        return jsonify({'error': f'vadduser: {err or out}'}), 500
    return jsonify({'created': f'{user}@{domain}'}), 201


@app.route('/domains/<domain>/users/<user>', methods=['DELETE'])
@_require_api_key
def delete_user(domain, user):
    if domain not in _domains():
        return jsonify({'error': f'{domain} not found'}), 404
    if not _USER_RE.match(user):
        return jsonify({'error': f'invalid user: {user}'}), 400
    out, err, rc = _run([f'{VPOPMAIL}/bin/vdeluser', f'{user}@{domain}'])
    if rc != 0:
        return jsonify({'error': f'vdeluser: {err or out}'}), 500
    return jsonify({'deleted': f'{user}@{domain}'})


@app.route('/domains/<domain>/users/<user>/password', methods=['PUT'])
@_require_api_key
def change_password(domain, user):
    if domain not in _domains():
        return jsonify({'error': f'{domain} not found'}), 404
    data = request.get_json(force=True, silent=True) or {}
    password = data.get('password', '').strip()
    if not password:
        return jsonify({'error': 'password is required'}), 400
    out, err, rc = _run([f'{VPOPMAIL}/bin/vpasswd', f'{user}@{domain}', password])
    if rc != 0:
        return jsonify({'error': f'vpasswd: {err or out}'}), 500
    return jsonify({'updated': f'{user}@{domain}'})


if __name__ == '__main__':
    port = int(os.environ.get('QMAIL_API_PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=False)
