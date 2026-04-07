#!/bin/sh
# Health check script for qmail container
# Returns 0 if healthy, 1 if unhealthy

set -e

# Check qmail-send is running (sv returns 0 if running)
sv check qmail-send >/dev/null 2>&1 || exit 1

# Check SMTP port 25 is accepting connections
nc -z 127.0.0.1 25 || exit 1

# Check Dovecot IMAP port 143
nc -z 127.0.0.1 143 || exit 1

# Check lighttpd port 80
nc -z 127.0.0.1 80 || exit 1

exit 0
