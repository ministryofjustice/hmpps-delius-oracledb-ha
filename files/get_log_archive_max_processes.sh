#!/bin/bash
#
#  Get log_archive_max_processes value from primary database.
#  This setting controls the amount of processes available for archiving, redo transport and FAL servers.
#

. ~/.bash_profile

sqlplus -s / as sysdba <<EOF
SET LINES 1000
SET PAGES 0
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR EXIT FAILURE
SELECT value
FROM   v\$parameter
WHERE  name='log_archive_max_processes';
EXIT
EOF