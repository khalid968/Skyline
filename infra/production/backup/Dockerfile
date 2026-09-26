# pg_dump/pg_restore of the same major version as the database, plus age.
FROM postgres:16-alpine
RUN apk add --no-cache age coreutils
COPY backup.sh restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh
ENTRYPOINT []
CMD ["/usr/local/bin/backup.sh"]
