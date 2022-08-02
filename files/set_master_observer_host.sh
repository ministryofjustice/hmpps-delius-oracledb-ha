#!/bin/bash
# Set the Master Observer Host Name

OBSERVER_CONFIG_FILE=$1
HOST_NAME=$2

. ~/.bash_profile

dgmgrl <<EODG 
connect /
set ObserverConfigFile=${OBSERVER_CONFIG_FILE}
set masterobserverhosts to ${HOST_NAME};
exit;
EODG