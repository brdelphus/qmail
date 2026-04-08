#!/bin/sh
# Health check script for dovecot container
# Returns 0 if healthy, 1 if unhealthy
# Respects service toggle environment variables.

set -e

# Check at least one mail service is running
CHECKED=0

if [ "${DOVECOT_IMAPS:-true}" = "true" ]; then
    nc -z 127.0.0.1 993 || exit 1
    CHECKED=1
elif [ "${DOVECOT_IMAP:-false}" = "true" ]; then
    nc -z 127.0.0.1 143 || exit 1
    CHECKED=1
fi

if [ "${DOVECOT_LMTP:-true}" = "true" ]; then
    nc -z 127.0.0.1 24 || exit 1
    CHECKED=1
fi

# If no services enabled, just check dovecot process
[ "$CHECKED" -eq 0 ] && pgrep -x dovecot >/dev/null

exit 0
