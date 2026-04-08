#!/bin/sh
# Health check script for qmail container
# Returns 0 if healthy, 1 if unhealthy
# Respects service toggle environment variables.

set -e

# Check qmail-send is running (sv returns 0 if running)
sv check qmail-send >/dev/null 2>&1 || exit 1

# Check enabled services
[ "${QMAIL_SMTP:-true}" = "true" ] && { nc -z 127.0.0.1 25 || exit 1; }
[ "${QMAIL_HTTP:-true}" = "true" ] && { nc -z 127.0.0.1 80 || exit 1; }

exit 0
