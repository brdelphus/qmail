require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

# Triggered when a message is copied/moved TO a Junk or Spam folder.
# Passes the authenticated IMAP username to the script so rspamd can track
# per-user Bayes statistics via the User: header.
if environment :matches "imap.cause" "COPY" {
    if environment :matches "imap.user" "*" {
        set "username" "${1}";
    }
    pipe :copy :args ["${username}"] "learn-spam.sh";
}
