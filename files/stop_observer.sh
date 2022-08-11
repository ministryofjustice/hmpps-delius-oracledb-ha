#!/bin/bash
# Stop Observing Named Observer

OBSERVER_CONFIG_FILE=$1
OBSERVER_NAME=$2

. ~/.bash_profile

dgmgrl <<EODG
connect /
set echo on
set ObserverConfigFile=${OBSERVER_CONFIG_FILE};
stop observer "${OBSERVER_NAME}";
exit;
EODG

COUNT=0

# The Observer process normally stops quickly but it is not immediate
OBSERVER_PROCESSES=$(ps -ef | grep $ORACLE_HOME | grep OBSERVER | grep -c dgmgrl)

# Allow up to 120 seconds for the Observer to stop
while [[ ((COUNT -lt 120)) && ((OBSERVER_PROCESSES -gt 0)) ]];
do
   OBSERVER_PROCESSES=$(ps -ef | grep $ORACLE_HOME | grep OBSERVER | grep -c dgmgrl)
   echo -ne "."
   sleep 1
   COUNT=$((COUNT+1))
done
echo

# If the Observer process is still running then kill it from the OS level
for x in $(ps -ef | grep $ORACLE_HOME | grep OBSERVER | grep dgmgrl | awk '{print $2}');
do
   echo "Killing process $x"
   kill -9 $x
done
