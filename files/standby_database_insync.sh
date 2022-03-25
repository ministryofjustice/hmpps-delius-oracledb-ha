#!/bin/bash
#
#  Check if the Standby Database is already in sync with the Primary (returns TRUE if this is the case).
#  Detected by Media Recovery actively waiting for the next redo
#

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
     v\$dataguard_status d
WHERE a.sequence# = b.sequence#
AND a.process = 'MRP0'
AND b.status = 'ACTIVE'
AND d.facility = 'Log Apply Services'
AND regexp_like (message, 'Media Recovery Waiting for T-1.S-'||a.sequence#||' \(in transit\)');
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