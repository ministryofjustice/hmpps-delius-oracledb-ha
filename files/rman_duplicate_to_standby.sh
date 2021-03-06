#!/bin/bash

PATH=$PATH:/usr/sbin:/usr/local/bin
THISSCRIPT=`basename $0`
RMANCMDFILE=/tmp/rmanduplicatestandby.cmd
RMANLOGFILE=/tmp/rmanduplicatestandby.log
RMANARCCLRLOG=/tmp/rmanarchiveclear.log
CPU_COUNT=$((`grep processor /proc/cpuinfo | wc -l`/2))

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
   echo "  $THISSCRIPT -t <primary db> -s <standby db> -p <sys password> -i < init pfile> -f [ -p <ssm parameter> ]"
   echo ""
   echo "  primary db              = primary database name"
   echo "  standby db              = standby database name"
   echo "  sys password            = database sys password"
   echo "  init pfile              = parameter initialization file"
   echo "  ssm parameter           = ssm parameter name to be updated"
   echo ""
   echo "  specifying -f will force a database duplication regardless of dataguard status"
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

startup_mount_standby() {
  sqlplus -s / as sysdba << EOF
  startup nomount pfile='${PARAMFILE}'
EOF
}

lookup_db_sys_password() {

 info "Looking up passwords to in aws ssm parameter to restore by sourcing /etc/environment"
  . /etc/environment

  PRODUCT=`echo $HMPPS_ROLE`
  SSMNAME="/${HMPPS_ENVIRONMENT}/${APPLICATION}/${PRODUCT}-database/db/oradb_sys_password"
  SYSPASS=`aws ssm get-parameters --region ${REGION} --with-decryption --name ${SSMNAME} | jq -r '.Parameters[].Value'`
  [ -z ${SYSPASS} ] && echo  "Password for sys in aws parameter store ${SSMNAME} does not exist"

}

rman_duplicate_to_standby () {

  echo "run"                                                                > $RMANCMDFILE
  echo "{"                                                                  >> $RMANCMDFILE
  for (( i=1; i<=${CPU_COUNT}; i++ ))
  do
    echo "  allocate channel ch${i} device type disk;"                      >> $RMANCMDFILE
  done
  for (( i=1; i<=${CPU_COUNT}; i++ ))
  do
    echo "  allocate auxiliary channel drch${i} device type disk;"          >> $RMANCMDFILE
  done
  echo "  duplicate target database"                                        >> $RMANCMDFILE
  echo "   for standby"                                                     >> $RMANCMDFILE
  echo "   from active database"                                            >> $RMANCMDFILE
  echo "    dorecover"                                                      >> $RMANCMDFILE
  echo "    spfile parameter_value_convert ('${primarydb}','${standbydb}')" >> $RMANCMDFILE
  echo "          set db_unique_name='${standbydb}'"                        >> $RMANCMDFILE
  echo "          set fal_server='${primarydb}'"                            >> $RMANCMDFILE
  echo "          set fal_client='${standbydb}'"                            >> $RMANCMDFILE
  echo "          set audit_file_dest='/u01/app/oracle/admin/${standbydb}/adump'" >> $RMANCMDFILE
  echo "          set log_archive_dest_1='location=use_db_recovery_file_dest valid_for=(all_logfiles, all_roles) db_unique_name=${standbydb}'" >> $RMANCMDFILE
  echo "          set log_archive_dest_2=''"   >> $RMANCMDFILE
  echo "          set log_archive_dest_3=''"   >> $RMANCMDFILE
  echo "          set dg_broker_config_file1='+DATA/${standbydb}/dg_broker1.dat'" >> $RMANCMDFILE
  echo "          set dg_broker_config_file2='+FLASH/${standbydb}/dg_broker2.dat'" >> $RMANCMDFILE
  echo "          set dg_broker_start='true'" >> $RMANCMDFILE
  echo "  nofilenamecheck;" >> $RMANCMDFILE
  echo "}" >> $RMANCMDFILE

  lookup_db_sys_password
  rman target sys/${SYSPASS}@${PRIMARYDB} auxiliary sys/${SYSPASS}@${STANDBYDB} cmdfile $RMANCMDFILE log $RMANLOGFILE << EOF
EOF

  info "Checking for errors"
  grep -i "ERROR MESSAGE STACK" $RMANLOGFILE >/dev/null 2>&1
  [ $? -eq 0 ] && error "Rman reported errors"
  info "Rman duplcate completed successfully"
}

perform_recovery () {
  info "Check standby recovery"
  sqlplus -s / as sysdba << EOF
    alter database close;
    alter database flashback on;
    alter database recover managed standby database disconnect;
    exit;
EOF
  [ $? -ne 0 ] && error "Recovering the standby" || info "Standby ${STANDBYDB} now recovering"
}

create_asm_spfile () {
  info "Add spfile to ASM"
  # Within 18c the SPFILE will have been duplicated to the DB_UNKNOWN directory within ASM, and an
  # alias created for it (instead of to the file system as would have happened with 11g).
  # To move the SPFILE to the intended destination it is necessary to bounce the instance using the temporary pfile.   
  # This will also remove the DB_UNKNOWN directory and aliases.
  sqlplus -s / as sysdba <<EOF
  create pfile='${ORACLE_HOME}/dbs/tmp.ora' from spfile;
  shutdown immediate;
  -- Database must be mounted when creating new SPFILE otherwise it will end up back in DB_UNKNOWN
  -- The restart is really only required for 18c but are harmless to do for 11g also.
  startup mount pfile='${ORACLE_HOME}/dbs/tmp.ora';
  -- Recreating the SPFILE will automatically remove the DB_UNKNOWN directory from ASM and aliases.
  create spfile='+DATA/${STANDBYDB}/spfile${STANDBYDB}.ora' from pfile='${ORACLE_HOME}/dbs/tmp.ora';
  shutdown immediate;
  startup mount;
EOF
  [ $? -ne 0 ] && error "Creating spfile in ASM"
  info "Create new pfile and remove spfile"
  echo "SPFILE='+DATA/${STANDBYDB}/spfile${STANDBYDB}.ora'" > ${ORACLE_HOME}/dbs/init${STANDBYDB}.ora
  rm ${ORACLE_HOME}/dbs/spfile${STANDBYDB}.ora ${ORACLE_HOME}/dbs/tmp.ora
}

add_to_crs () {
  info "Add ${standbydb} database resource to CRS if not already"
  sqlplus -s / as sysdba <<EOF
   shutdown abort
   exit
EOF
  # Allow slight pause for CRS to detect database down as shutdown using sqlplus
  sleep 30
  srvctl status database -d ${STANDBYDB} > /dev/null
  if [ $? -ne 0 ]
  then
    srvctl add database -d ${STANDBYDB} -o ${ORACLE_HOME} -p +DATA/${STANDBYDB}/spfile${STANDBYDB}.ora -r PHYSICAL_STANDBY -s MOUNT -t IMMEDIATE -i ${STANDBYDB} -n ${PRIMARYDB} -y AUTOMATIC -a "DATA,FLASH"
    [ $? -ne 0 ] && error "Adding ${STANDBYDB} to CRS" || info "Added ${STANDBYDB} to CRS"
  fi
  srvctl start database -d ${STANDBYDB} -o MOUNT
  [ $? -ne 0 ] && error "Starting ${STANDBYDB} CRS resource" || info "Started ${STANDBYDB} with CRS resource"

 }

configure_rman () {
  rman target / <<EOF
    CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;
EOF
}

remove_orphaned_archive () {
  info "Remove orphaned archived redo logs"

  V_PARAMETER=v\$parameter
  V_INSTANCE=v\$instance

  X=`sqlplus -s / as sysdba <<EOF
      set feedback off heading off echo off verify off
      SELECT     'export ARCHIVE_DEST='||p.value||'/'|| i.instance_name||'/archivelog'
      FROM       $V_PARAMETER   p
      CROSS JOIN $V_INSTANCE   i
      WHERE      p.name = 'db_recovery_file_dest';     
EOF
  `
  eval $X
  [ $? -ne 0 ] && error "Getting archive destination" || info "Got archive destination"

  # As soon as we catalog the recovery destination, the orphaned redo logs
  # will be automatically removed from ASM by Oracle.  So we simply need to
  # crosscheck and delete the associated records.
  rman target / log $RMANARCCLRLOG <<EOF
      CATALOG START WITH '$ARCHIVE_DEST';
      CROSSCHECK ARCHIVELOG ALL;
      DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;
      exit
EOF
  [ $? -ne 0 ] && error "Removing orphaned archivelogs" || info "Removed orphaned archivelogs"
}

remove_asm_directories () {
  sleep 10
  info "Shutdown instance ${STANDBYDB}"
  sqlplus / as sysdba << EOF
  shutdown abort;
EOF
  [ $? -ne 0 ] && error "Shutting down ${STANDBYDB}"

  sleep 10
  set_ora_env +ASM

  for VG in DATA FLASH
  do
    info "Remove directory ${STANDBYDB} in ${VG} volume group"
    asmcmd ls +${VG}/${STANDBYDB} > /dev/null 2>&1
    if [ $? -eq 0 ]
    then
      asmcmd rm -rf +${VG}/${STANDBYDB}
      [ $? -ne 0 ] && error "Removing directory ${STANDBYDB} in ${VG}"
    else
      info "No ${STANDBYDB}directory in ${VG} to delete"
    fi
  done
  # From 18c we must have the second level ASM directories in place before restoring SPFILE
  # as it will now fail rather than defaulting to $ORACLE_HOME/dbs as it did previously.
  for VG in DATA FLASH
  do
    info "Create directory ${STANDBYDB} in ${VG} volume group"
    asmcmd mkdir +${VG}/${STANDBYDB}
  done
}

remove_standby_parameter_files () {
  set_ora_env ${STANDBYDB}
  ls ${ORACLE_HOME}/dbs/*${STANDBYDB}* | egrep -v "${PARAMFILE}|orapw${STANDBYDB}" | xargs -r rm 
  [ $? -ne 0 ] && error "Removing standby parameter files"
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
SSM_PARAMETER=UNSPECIFIED

while getopts "t:s:i:fp:" opt
do
  case $opt in
    t) PRIMARYDB=$OPTARG ;;
    s) STANDBYDB=$OPTARG ;;
    i) PARAMFILE=$OPTARG ;;
    f) FORCERESTORE=TRUE ;;
    p) SSM_PARAMETER=$OPTARG ;;
    *) usage ;;
  esac
done
info "Primary Database = ${PRIMARYDB}"
info "Standby Database = ${STANDBYDB}"
info "SSM parameter    = $SSM_PARAMETER"
if [[ "${FORCERESTORE}" == "TRUE" ]];
then
   info "Force Restore selected"
fi

primarydb=`echo "${PRIMARYDB}" | tr '[:upper:]' '[:lower:]'`
standbydb=`echo "${STANDBYDB}" | tr '[:upper:]' '[:lower:]'`

# ------------------------------------------------------------------------------
# Check parameters
# ------------------------------------------------------------------------------
[ -z "$1" ] && usage

# Create audit directory
mkdir -p /u01/app/oracle/admin/${standbydb}/adump
[ $? -ne 0 ] && error "Creating the audit directory"

# Check if standby database configured in dgbroker
set_ora_env ${STANDBYDB}
dgmgrl /  "show configuration" | grep "Physical standby database"  | grep "${standbydb}" > /dev/null
PHYSICAL_STANDBY_CONFIG=$?

if [[ ${PHYSICAL_STANDBY_CONFIG} -eq 0 ]];
then
  info "${standbydb} already configured in dgbroker"
else
  info "${standbydb} not configured in dgbroker"
fi

# Check if ORA-16700 error code associated with standby (requires rebuild)
dgmgrl /  "show database ${standbydb}" | grep "ORA-16700: the standby database has diverged from the primary database" > /dev/null
PHYSICAL_STANDBY_DIVERGENCE=$?

if [[ ${PHYSICAL_STANDBY_DIVERGENCE} -eq 0 ]];
then
  info "${standbydb} has diverged from the primary database"
fi

# Check if ORA-16766 error code associated with standby (requires rebuild)
dgmgrl /  "show database ${standbydb}" | grep "ORA-16766: Redo Apply is stopped" > /dev/null
REDO_APPLY_STOPPED=$?

if [[ ${REDO_APPLY_STOPPED} -eq 0 ]];
then
  info "${standbydb} redo apply has stopped when it should have been running"
fi

# Check if ORA-16603 error code associated with standby (configuration ID mismatch)
dgmgrl /  "show database ${standbydb}" | grep "ORA-16603: Data Guard broker detected a mismatch in configuration ID" > /dev/null
DG_CONFIGURATION_MISMATCH=$?

if [[ ${DG_CONFIGURATION_MISMATCH} -eq 0 ]];
then
  info "${standbydb} has a mismatched dataguard configuration"
fi

if [[ ${PHYSICAL_STANDBY_CONFIG} -eq 0 && ${PHYSICAL_STANDBY_DIVERGENCE} -ge 1 && ${REDO_APPLY_STOPPED} -ge 1 && ${DG_CONFIGURATION_MISMATCH} -ge 1 && "${FORCERESTORE}" != "TRUE" ]];
then
  info "${standbydb} already configured in dgbroker, can assume no duplicate required"
else

  # Shutdown standby instance and remove standby database from DATA and FLASH asm diskgroups
  remove_asm_directories

  # Remove unneccesary standby parameter files
  remove_standby_parameter_files

  # Startup no mount standby instance for rman duplicate
  startup_mount_standby

  # Perform rman duplicate
  rman_duplicate_to_standby

  # Add to CRS
  create_asm_spfile
  add_to_crs

  # Perform recovery
  perform_recovery

  # Configure RMAN
  configure_rman

  # Remove orphaned archivelogs left by previous incarnation
  remove_orphaned_archive
fi

info "Update ssm duplicate parameter if specified"
if [ "${SSM_PARAMETER}" != "UNSPECIFIED" ]
then  
  . /etc/environment
  aws ssm put-parameter --region ${REGION} --value "CompletedHA" --name "${SSM_PARAMETER}" --overwrite --type String
  [ $? -ne 0 ] && error "Updating ssm duplicate parameter"
fi

info "End"

# Exit with success status if no error found
exit 0