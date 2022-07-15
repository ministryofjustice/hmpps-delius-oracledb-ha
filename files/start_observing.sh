#!/bin/bash
# Start Observing

OBSERVER_CONFIG_FILE=$1

. ~/.bash_profile

dgmgrl <<EODG
connect /
set ObserverConfigFile=${OBSERVER_CONFIG_FILE}
start observering;
exit;
EODG