#!/bin/bash

. /home/oracle/.bash_profile

LOCKFILE="/home/oracle/run_observer.lock"

# Check if the lock file is already locked by another instance
exec 200>"${LOCKFILE}"
if ! flock -n -x 200; then
  echo "Another instance of this script is already running."
  exit 1
fi

DATA_GUARD_WALLET=${ORACLE_BASE}/wallets/dg_wallet

# Populate the TNSNAMES.ora file
echo ${PRIMARYDB_TNS} > ${ORACLE_HOME}/network/admin/tnsnames.ora
echo ${STANDBYDB1_TNS} >> ${ORACLE_HOME}/network/admin/tnsnames.ora
echo ${STANDBYDB2_TNS} >> ${ORACLE_HOME}/network/admin/tnsnames.ora

# Get the names of the databases
PRIMARYDB=$(echo ${PRIMARYDB_TNS} | awk -F= '{print $1}')
STANDBYDB1=$(echo ${STANDBYDB1_TNS} | awk -F= '{print $1}')
STANDBYDB2=$(echo ${STANDBYDB2_TNS} | awk -F= '{print $1}')


function get_sys_password()
{
SYSPWD=$(aws ssm get-parameters --region eu-west-2 --with-decryption --name ${PASSWORD_PARAMETER_PATH} | jq -r '.Parameters[].Value')
}

function initialize_dg_wallet()
{
mkstore -wrl ${DATA_GUARD_WALLET} -createCredential ${PRIMARYDB} sys ${SYSPWD}
if [[ ! -z ${STANDBYDB1} ]];
then
   mkstore -wrl ${DATA_GUARD_WALLET} -createCredential ${STANDBYDB1} sys ${SYSPWD}
   if [[ ! -z ${STANDBYDB2} ]];
   then
      mkstore -wrl ${DATA_GUARD_WALLET} -createCredential ${STANDBYDB2} sys ${SYSPWD}
   fi
fi
}

function update_dg_wallet()
{
mkstore -wrl ${DATA_GUARD_WALLET} -modifyCredential ${PRIMARYDB} sys ${SYSPWD}
if [[ ! -z ${STANDBYDB1} ]];
then
   mkstore -wrl ${DATA_GUARD_WALLET} -modifyCredential ${STANDBYDB1} sys ${SYSPWD}
   if [[ ! -z ${STANDBYDB2} ]];
   then
      mkstore -wrl ${DATA_GUARD_WALLET} -modifyCredential ${STANDBYDB2} sys ${SYSPWD}
   fi
fi
}

function start_observer()
{
echo -e "start observer dg_observer in background file is ${HOME}/fsfo.dat logfile is ${HOME}/observer.log connect identifier is ${PRIMARYDB};" | dgmgrl /@${PRIMARYDB}
}

function wait_for_observer_to_stop()
{
# Sometimes it can take a little while for the observer to stop, so allow a few retries
COUNT=0
MAXTRIES=10
WAITSECS=60
NUMOBSERVERS=$(echo -e "show observer;" | dgmgrl -silent /@${PRIMARYDB} | grep -Ec "Host Name:\s+${HOSTNAME}$")
while [[ $NUMOBSERVERS -gt 0 ]];
do
   COUNT=$((COUNT+1))
   if [[ COUNT > MAXTRIES ]];
   then
      echo "Cannot stop the observer"
      exit 1
   fi
   sleep ${WAITSECS}
   NUMOBSERVERS=$(echo -e "show observer;" | dgmgrl -silent /@${PRIMARYDB} | grep -Ec "Host Name:\s+${HOSTNAME}$")
done
}

function stop_observer()
{
echo -e "stop observer all;" | dgmgrl /@${PRIMARYDB}
wait_for_observer_to_stop
}

get_sys_password
initialize_dg_wallet
stop_observer # Ensure a clean restart
start_observer

echo
ps -ef | grep -i dg_observer | grep -v grep

# Poll for Password Changes
while true;
do
   ORA=$(echo exit | sqlplus -L -S /@DNDA as sysdba | grep ORA- | awk -F: '{print $1}')
   if [[ "${ORA}" == "ORA-01017" || "${ORA}" == "ORA-28000" ]];
   then
     echo "Password error detected; updating password wallet"
     get_sys_password
     update_dg_wallet
     stop_observer
     start_observer
   fi
   sleep 60
done
