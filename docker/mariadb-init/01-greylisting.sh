#!/bin/sh
# Creates the greylisting database, user, and schema on first MariaDB start.
# Runs automatically from /docker-entrypoint-initdb.d/ — only on a fresh volume.
# Credentials come from the mariadb service environment (set in docker-compose.yml).

GREYLIST_DB="${GREYLIST_DB:-greylisting}"
GREYLIST_USER="${GREYLIST_USER:-greylisting}"
GREYLIST_PASS="${GREYLIST_PASS:-changeme_grey}"

mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${GREYLIST_DB}\`;
CREATE USER IF NOT EXISTS '${GREYLIST_USER}'@'%' IDENTIFIED BY '${GREYLIST_PASS}';
GRANT ALL PRIVILEGES ON \`${GREYLIST_DB}\`.* TO '${GREYLIST_USER}'@'%';
USE \`${GREYLIST_DB}\`;
CREATE TABLE IF NOT EXISTS greylisting (
  relay_ip        VARCHAR(39)                           NOT NULL,
  sender          VARCHAR(255)                          NOT NULL,
  recipient       VARCHAR(255)                          NOT NULL,
  block_expires   DATETIME                              NOT NULL,
  record_expires  DATETIME                              NOT NULL,
  blocked_count   INT          NOT NULL DEFAULT 0,
  passed_count    INT          NOT NULL DEFAULT 0,
  aborted_count   INT          NOT NULL DEFAULT 0,
  origin_type     ENUM('MANUAL','SCRIPT','GREYLIST')    NOT NULL DEFAULT 'GREYLIST',
  PRIMARY KEY (relay_ip, sender, recipient)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
FLUSH PRIVILEGES;
SQL
