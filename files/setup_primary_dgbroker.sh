#!/bin/bash

PATH=/usr/sbin:/usr/local/bin:$PATH
THISSCRIPT=`basename $0`
OUTPUT=/tmp/`basename $0 .sh`.out
>${OUTPUT}

info () {
  T=`date +"%D %T"`
    echo -e "INFO : $THISSCRIPT : $T : $1 "| tee -a ${OUTPUT}
}

error () {
  T=`date +"%D %T"`
  echo -e "ERROR : $THISSCRIPT : $T : $1" | tee -a ${OUTPUT}
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

setup_dgbroker_parameters () {
  info "Change dgbroker database parameters ..."
  sqlplus -s / as sysdba << EOF
    alter system set dg_broker_start=false scope=both;
    alter system set dg_broker_config_file1='+DATA/${PRIMARYDB}/dg_broker1.dat' scope=both;
    alter system set dg_broker_config_file2='+FLASH/${PRIMARYDB}/dg_broker2.dat' scope=both;
    alter system set dg_broker_start=true scope=both;
EOF
  [ $? -ne 0 ] && error "Changing dgbroker database parameters" || info "Changed dgbroker parameters"
}

create_dgbroker_configuration () {
  lookup_db_sys_password
  prefix=`echo ${PRIMARYDB: (-3)} | tr '[:upper:]' '[:lower:]'`
  info "Create dgbroker configuration"
  dgmgrl /  <<EOF
    create configuration ${prefix}_dg_config as primary database is ${primarydb} connect identifier is ${primarydb};
    add database ${standbydb} as connect identifier is ${standbydb} maintained as physical;
    enable configuration;
    connect sys/${SYSPASS}@${standbydb};
    shutdown immediate;
    startup mount;
EOF
  [ $? -ne 0 ] && error "Creating dgbroker configuration" || info "Created ${prefix}_dg_config dgbroker configuration"
}

lookup_db_sys_password() {

 info "Looking up passwords to in aws ssm parameter to restore by sourcing /etc/environment"
  . /etc/environment

  PRODUCT=`echo $HMPPS_ROLE`
  SSMNAME="/${HMPPS_ENVIRONMENT}/${APPLICATION}/${PRODUCT}-database/db/oradb_sys_password"
  SYSPASS=`aws ssm get-parameters --region ${REGION} --with-decryption --name ${SSMNAME} | jq -r '.Parameters[].Value'`
  [ -z ${SYSPASS} ] && error "Password for sys in aws parameter store ${SSMNAME} does not exist"

}

add_standby_to_dgbroker () {
  info "Add ${standbydb} to dgbroker configuration"
  info " Lookup sys password"
  lookup_db_sys_password
  dgmgrl /  <<EOF
    add database ${standbydb} as connect identifier is ${standbydb} maintained as physical;
    enable database ${standbydb};
    connect sys/${SYSPASS}@${standbydb};
    shutdown immediate;
    startup mount;
EOF
  [ $? -ne 0 ] && error "Adding to ${standbydb} dgbroker configuration" || info "Added ${standbydb} to dgbroker"
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

# Source database environment
set_ora_env ${PRIMARYDB}

info "Check dg broker configuration exists"
dgmgrl /   "show configuration" > /dev/null
if [ $? -ne 0 ]
then
  setup_dgbroker_parameters
  sleep 60
  create_dgbroker_configuration
else
  STANDBYARRAY=(`dgmgrl /  "show configuration" | grep "Physical standby database" | cut -d'-' -f1 | sed -e 's/^[[:space:]]*//'`)
  let MATCH=0

  for NAME in "${STANDBYARRAY[@]}"
  do
    if [ "${standbydb}" = "${NAME}" ]
    then
      MATCH=1
      info "${standbydb} already configured in dgbroker"
      dgmgrl /  "show configuration" | grep "Physical standby database"  | grep ${standbydb} | grep "(disabled)" > /dev/null
      DG_DISABLED=$?
      if [ $DG_DISABLED -eq 0 ];
      then
         info "${standbydb} configuration is disabled - re-enabling"
         dgmgrl /  "enable database ${standbydb}" 
      fi
      break
    fi
  done

  if [ $MATCH -eq 0 ]
  then
    add_standby_to_dgbroker
  fi
fi
