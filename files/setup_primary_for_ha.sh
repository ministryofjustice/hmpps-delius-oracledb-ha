#!/bin/bash

export PATH=/usr/sbin:/usr/local/bin:$PATH
THISSCRIPT=`basename $0`

info () {
  T=`date +"%D %T"`
    echo -e "INFO : $THISSCRIPT : $T : $1"
}

error () {
  T=`date +"%D %T"`
  echo -e "ERROR : $THISSCRIPT : $T : $1"
  exit 1
  }

 usage () {
   echo ""
   echo "Usage:"
   echo ""
   echo "  $THISSCRIPT -t <primary db> -s <standby db>"
   echo ""
   echo "  primary db              = primary database name"
   echo "  standby db              = standby database name"
   echo ""
   exit 1
}

set_ora_env () {
  export ORAENV_ASK=NO
  export ORACLE_SID=$1
  . oraenv
  unset SQLPATH
  unset TWO_TASK
  unset LD_LIBRARY_PATH
  export NLS_DATE_FORMAT=YYMMDDHH24MI
}

configure_primary_for_ha () {
  set_ora_env ${PRIMARYDB}
  V_DATABASE=v\$database
  X=`sqlplus -s / as sysdba <<EOF
     set feedback off heading off echo off verify off
     select 'LOG_MODE='||log_mode,
            'FLASHBACK_ON='||flashback_on,
            'FORCE_LOGGING='||force_logging
      from $V_DATABASE;
EOF`

  eval $X
  if [ "$LOG_MODE" != "ARCHIVELOG" ]
  then
    sqlplus -s / as sysdba << EOF
    set feedback off heading off echo off verify off
    shutdown immediate
    startup mount
    alter database archivelog;
    alter database open;
    exit;
EOF
  fi

    sqlplus -s / as sysdba << EOF
    alter database force logging;
    alter database flashback on;
    alter system set log_archive_dest_1='location=use_db_recovery_file_dest valid_for=(all_logfiles,all_roles) db_unique_name=${primarydb}' scope=both;
    alter system set log_archive_config='dg_config=(${primarydb},${primarydb}s1,${primarydb}s2)' scope=both;
    alter system set log_archive_dest_${n}='service=${standbydb} affirm sync valid_for=(online_logfiles,primary_role) db_unique_name=${standbydb}' scope=both;
    alter system set log_archive_dest_state_${n}=enable scope=both;
    alter system set fal_server='${primarydb}s1, ${primarydb}s2' scope=both;
    alter system set fal_client='${primarydb}' scope=both;
    alter system set standby_file_management=auto scope=both;
EOF

    rman target / << EOF
      CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 14 DAYS;
      CONFIGURE CONTROLFILE AUTOBACKUP ON;
      CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE 'SBT_TAPE' TO '%F';
      CONFIGURE DEVICE TYPE 'SBT_TAPE' PARALLELISM 1 BACKUP TYPE TO COMPRESSED BACKUPSET;
      CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO 'SBT_TAPE';
EOF
}

create_standby_logfiles () {
  info "Create standby log files"
  sqlplus -s / as sysdba << EOF
  set head off pages 1000 feed off
  declare
    cursor c1 is
      select 'alter database add standby logfile thread 1 group '||rn||' size '||mb cmd
      from ( with maxgroup as
            (select max(group#) as mr, max(bytes) as mb from v\$log)
             select mr, mb, rownum as rn
             from maxgroup
             connect by level <= ((2*mr)+1))
      where rn > mr
      and rn not in (select group# from v\$standby_log);

      sql_stmt varchar2(400);

  begin
    for r1 in c1
    loop
      sql_stmt := r1.cmd;
      execute immediate sql_stmt;
    end loop;
  end;
  /  
EOF
  [ $? -ne 0 ] && error "Creating standby log files" || info "Created standby log files"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
info "Start"

# ------------------------------------------------------------------------------
# Check that we are running as the correct user (oracle)
# ------------------------------------------------------------------------------
info "Validating user"
THISUSER=`id | cut -d\( -f2 | cut -d\) -f1`
[ "$THISUSER" != "oracle" ] && error "Must be oracle to run this script"
info "User ok"

# ------------------------------------------------------------------------------
# Check that we have been given all the required arguments
# ------------------------------------------------------------------------------
info "Retrieving arguments"
[ -z "$1" ] && usage

TARGETDB=UNSPECIFIED

while getopts "t:s:" opt
do
  case $opt in
    t) PRIMARYDB=$OPTARG ;;
    s) STANDBYDB=$OPTARG ;;
    *) usage ;;
  esac
done
info "Primary Database = $PRIMARYDB"
info "Standby Database = $STANDBYDB"

primarydb=`echo "${PRIMARYDB}" | tr '[:upper:]' '[:lower:]'`
standbydb=`echo "${STANDBYDB}" | tr '[:upper:]' '[:lower:]'`

# ------------------------------------------------------------------------------
# Check parameters
# ------------------------------------------------------------------------------
[ -z "$1" ] && usage

# Configure log_archive_dest_<n> 
if [[ ${STANDBYDB} =~ .*S1 ]]
then
   n=2
elif [[ ${STANDBYDB} =~ .*S2 ]] 
then
   n=3
fi

# Configure database parameters
configure_primary_for_ha

# Create redo standby log files they do not exist
create_standby_logfiles