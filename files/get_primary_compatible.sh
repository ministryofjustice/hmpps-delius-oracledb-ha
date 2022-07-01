#!/bin/bash
#
#  Get compatible value from primary database
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
WHERE  name='compatible';
EXIT
EOF

