require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

# Triggered when a message is moved OUT of Junk/Spam to any folder.
# Skip if the destination is Trash (user deleting spam, not correcting it).
# Passes the authenticated IMAP username for per-user Bayes tracking in rspamd.
if allof(
    environment :matches "imap.cause" "COPY",
    not environment :is "imap.mailbox" "Trash"
) {
    if environment :matches "imap.user" "*" {
        set "username" "${1}";
    }
    pipe :copy :args ["${username}"] "learn-ham.sh";
}
