FROM rspamd/rspamd:latest

USER root
COPY docker/rspamd/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 && chown 11333:11333 /etc/rspamd/override.d
USER 11333:11333

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/rspamd", "-f"]
