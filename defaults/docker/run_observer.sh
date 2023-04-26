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

# Get the SYS password
SYSPWD=$(aws ssm get-parameters --region eu-west-2 --with-decryption --name ${PASSWORD_PARAMETER_PATH} | jq -r '.Parameters[].Value')

# Initialize the Data Guard Wallet
mkstore -wrl ${DATA_GUARD_WALLET} -createCredential ${PRIMARYDB} sys ${SYSPWD}

if [[ ! -z ${STANDBYDB1} ]];
then
   mkstore -wrl ${DATA_GUARD_WALLET} -createCredential ${STANDBYDB1} sys ${SYSPWD}
   if [[ ! -z ${STANDBYDB2} ]];
   then
      mkstore -wrl ${DATA_GUARD_WALLET} -createCredential ${STANDBYDB2} sys ${SYSPWD}
   fi
fi

# Start the Data Guard Observer
echo -e "start observer in background file is ${HOME}/fsfo.dat logfile is ${HOME}/observer.log connect identifier is ${PRIMARYDB};" | dgmgrl -silent