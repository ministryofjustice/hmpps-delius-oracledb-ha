#!/bin/bash

. ~/.bash_profile

sqlplus -s / as sysdba <<EOF
SET LINES 1000
SET PAGES 0
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR EXIT FAILURE
SELECT 
  CASE 
    WHEN a.sequence# IS NOT NULL
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