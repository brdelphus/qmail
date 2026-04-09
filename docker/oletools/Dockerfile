FROM python:3.12-slim

ARG OLETOOLS_VERSION=0.60.1
# Pin to a specific commit — olefy has no releases/tags
ARG OLEFY_COMMIT=e9e593bf29799e3f61023125cbfd5cd3c1338cf4

RUN apt-get update \
 && apt-get install -y --no-install-recommends wget netcat-openbsd libmagic1 \
 && rm -rf /var/lib/apt/lists/*

# Install oletools in an isolated venv
RUN python -m venv /opt/olefy \
 && /opt/olefy/bin/pip install --no-cache-dir "oletools==${OLETOOLS_VERSION}" python-magic

# Download olefy — the TCP daemon that wraps olevba for rspamd
RUN wget -qO /opt/olefy/bin/olefy.py \
        "https://raw.githubusercontent.com/HeinleinSupport/olefy/${OLEFY_COMMIT}/olefy.py" \
 && chmod 755 /opt/olefy/bin/olefy.py

# Unprivileged user — no home, no shell
RUN useradd -r -d /nonexistent -s /usr/sbin/nologin olefy

USER olefy

ENV PATH=/opt/olefy/bin:$PATH \
    OLEFY_PYTHON_PATH=/opt/olefy/bin/python \
    OLEFY_OLEVBA_PATH=/opt/olefy/bin/olevba \
    # Listen on all interfaces so rspamd can reach it over the compose network
    OLEFY_BINDADDRESS=0.0.0.0 \
    OLEFY_BINDPORT=11343 \
    # Use shared memory for temp files — avoids disk I/O and leaves no traces
    OLEFY_TMPDIR=/dev/shm \
    OLEFY_LOGLEVEL=20 \
    OLEFY_LOG_MALFORMED=1

EXPOSE 11343

CMD ["/opt/olefy/bin/python", "/opt/olefy/bin/olefy.py"]
