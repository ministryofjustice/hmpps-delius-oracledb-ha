#!/bin/bash
# Get all the Observer Host Names

OBSERVER_CONFIG_FILE=$1

. ~/.bash_profile

dgmgrl <<EODG | awk '/Host Name:/{print $3}'
connect /
set ObserverConfigFile=${OBSERVER_CONFIG_FILE}
show observers;
exit;
EODG

# Do not use grep return code
exit 0