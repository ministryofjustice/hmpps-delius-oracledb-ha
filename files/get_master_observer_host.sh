#!/bin/bash
# Get the Master Observer Host Name

OBSERVER_CONFIG_FILE=$1

. ~/.bash_profile

dgmgrl <<EODG | awk '/^Observer.*Master$/{flag=1}/Host Name:/{if(flag==1){print $3}}/Last Ping/{flag=0}'
connect /
set ObserverConfigFile=${OBSERVER_CONFIG_FILE}
show observers;
exit;
EODG