#!/bin/bash

PATH=$PATH:/usr/sbin:/usr/local/bin
THISSCRIPT=`basename $0`
RMANCMDFILE=/tmp/rmanduplicatestandby.cmd
RMANLOGFILE=/tmp/rmanduplicatestandby.log


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
   echo "  $THISSCRIPT -t <primary db> -s <standby db> -p <sys password> -i < init pfile>"
   echo ""
   echo "  primary db              = primary database name"
   echo "  standby db              = standby database name"
   echo "  sys password            = database sys password"
   echo "  init pfile              = parameter initialization file"
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

lookup_db_user () {

  INSTANCE_ID=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`
  REGION=`wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//'`
  ENVIRONMENTNAME=`aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=environment-name" --region ${REGION} | jq -r '.Tags[].Value'`
  APPLICATION=`aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=application" --region ${REGION} | jq -r '.Tags[].Value'`
  NAME=`aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=Name" --region ${REGION} | jq -r '.Tags[].Value'`
  DATABASE="`echo $NAME | sed -e s/^${ENVIRONMENTNAME}-// -e s/-.*//`-database"
  SSMNAME="/${ENVIRONMENTNAME}/${APPLICATION}/${DATABASE}/db/oradb_sys_password"
  SYSPASS=`aws ssm get-parameters --region ${REGION} --with-decryption --name ${SSMNAME} | jq -r '.Parameters[].Value'`

}

rman_duplicate_to_standby () {

  echo "run"                                                                > $RMANCMDFILE
  echo "{"                                                                  >> $RMANCMDFILE
  echo "  allocate channel ch1 device type disk;"                           >> $RMANCMDFILE
  echo "  allocate channel ch2  device type disk;"                          >> $RMANCMDFILE
  echo "  allocate auxiliary channel drch1 type disk;"                      >> $RMANCMDFILE
  echo "  allocate auxiliary channel drch2 type disk;"                      >> $RMANCMDFILE
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

  lookup_db_user
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
	  alter database open read only;
	  alter database close;
    alter database flashback on;
	  alter database recover managed standby database using current logfile disconnect;
    exit;
EOF
  [ $? -ne 0 ] && error "Recovering the standby" || info "Standby ${STANDBYDB} now recovering"
}

create_asm_spfile () {
  info "Add spfile to ASM"
  sqlplus -s / as sysdba <<EOF
  create pfile='${ORACLE_HOME}/dbs/tmp.ora' from spfile;
  create spfile='+DATA/${STANDBYDB}/spfile${STANDBYDB}.ora' from pfile='${ORACLE_HOME}/dbs/tmp.ora';
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

while getopts "t:s:i:" opt
do
  case $opt in
    t) PRIMARYDB=$OPTARG ;;
    s) STANDBYDB=$OPTARG ;;
    i) PARAMFILE=$OPTARG ;;
    *) usage ;;
  esac
done
info "Primary Database = ${PRIMARYDB}"
info "Standby Database = ${STANDBYDB}"

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

if [ $? -eq 0 ]
then
  info "${standbydb} already configured in dgbroker, can assume no duplicate required"
else
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
fi
info "End"