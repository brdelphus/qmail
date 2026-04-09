# Rspamd controller worker settings.
# Password hash generated with: docker compose exec rspamd rspamadm pw -p <password>
# Update RSPAMD_PASSWORD in .env and regenerate if the password changes.
#
# This password is used by:
#   - Dovecot IMAPSieve learn-spam.sh / learn-ham.sh (via /learnspam, /learnham)
#   - Web UI at http://host:11334/

password = "$2$d3pdgk5tau7xjru4qx4b5dcfx9dyujsn$tyor711d6crzfah7q6ap8r7g7hm4136mt34a58q7hruwfh3kjpub";
