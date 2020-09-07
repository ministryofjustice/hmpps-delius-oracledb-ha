#!/bin/bash

. ~/.bash_profile

INSYNC=$(
sqlplus -s / as sysdba <<EOF
SET LINES 1000
SET PAGES 0
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR EXIT FAILURE
-- Return FALSE if no rows returned
SELECT
  CASE
    WHEN MAX(a.sequence#) IS NOT NULL
    THEN 'TRUE '
   ELSE 'FALSE' END
FROM v\$managed_standby a,
     v\$standby_log b,
     v\$log c,
     v\$dataguard_status d
WHERE a.sequence# = b.sequence#
AND a.process = 'MRP0'
AND b.status = 'ACTIVE'
AND c.sequence# = b.sequence#
AND c.status = 'CURRENT'
AND d.facility = 'Log Apply Services'
AND regexp_like (message, 'Media Recovery Waiting for thread 1 sequence '||a.sequence#||' \(in transit\)');
EXIT
EOF
)
# If the above fails with an error then we are not in sync
if [ $? != 0 ];
then
   echo FALSE
else
   echo $INSYNC
fi