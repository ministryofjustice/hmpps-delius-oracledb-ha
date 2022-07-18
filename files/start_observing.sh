#!/bin/bash
# Start Observing

OBSERVER_CONFIG_FILE=$1
CONNECT_IDENTIFIER=$2
LOG_FILE=$3
OBSERVER_FILE=$4

. ~/.bash_profile

dgmgrl <<EODG
connect /
set ObserverConfigFile=${OBSERVER_CONFIG_FILE};
start observer in background file is ${OBSERVER_FILE} logfile is ${LOG_FILE} connect identifier is ${CONNECT_IDENTIFIER};
exit;
EODG