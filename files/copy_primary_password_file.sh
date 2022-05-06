#!/bin/bash

. ~/.bash_profile

export DBUNIQUENAME=${ORACLE_SID}
export SOURCE_PASSWORD_FILE=${ORACLE_HOME}/dbs/orapw${DBUNIQUENAME}

export ORACLE_SID=+ASM; 
export ORAENV_ASK=NO ; 
. oraenv

. /etc/environment 
SYS_PASSWORD=$(aws ssm get-parameters --region ${REGION} --with-decryption --name /${HMPPS_ENVIRONMENT}/${APPLICATION}/oem-database/db/oradb_sys_password | jq -r '.Parameters[].Value')

asmcmd <<EOASMCMD
cp sys/${SYS_PASSWORD}@${PRIMARY_HOSTNAME}.+ASM:+DATA/${PRIMARY_SID}/orapw${PRIMARY_SID} +DATA/${DBUNIQUENAME}/orapw${DBUNIQUENAME}
EOASMCMD
