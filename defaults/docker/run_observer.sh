#!/bin/bash

. /home/oracle/.bash_profile

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

function stop_observer()
{
echo -e "stop observer all;" | dgmgrl /@${PRIMARYDB}
}

get_sys_password
initialize_dg_wallet
stop_observer # Ensure a clean restart
start_observer

echo
ps -ef | grep -i dg_observer | grep -v grep
echo

# Poll for Password Changes
while true;
do
   ORA=$(echo exit | sqlplus -L -S /@DNDA as sysdba | grep ORA- | awk -F: '{print $1}')
   if [[ "${ORA}" == "ORA-01017" || "${ORA}" == "ORA-28000" ]];
   then
     echo "Password error detected; updating password wallet"
     stop_observer
     get_sys_password
     update_dg_wallet
     start_observer
   fi
   sleep 60
done