#!/bin/sh
#
# This script is intended to provide CRS Support for Starting and
# Stopping a single Data Guard Observer on the current host.
#
# It assumes that an Observer has already been configured on the
# current host as it provides only stop/start services (not
# configuration).   Attempt to stop or start an observer on a host
# where one has not already been configured may fail.
#
# If an attempt is made to stop the Master Observer then any Backup
# Observers will be stopped first, even if they are running on
# other hosts.
#
# This script takes no parameters as it determines the name of
# the Observer dynamically using the Data Guard broker.

. ~/.bash_profile

export CONFIG="set ObserverConfigFile=${ORACLE_BASE}/dg_observer/observer.ora;"

function usage()
{
echo "$0 [start|stop|clean|status|check]"
echo 
echo "start  - start an Observer on this host (must already be configured including password wallet)"
echo "stop   - stop currently running Observer on this host"
echo "clean  - restart running Observer on this host"
echo "status - report all Observers within current Data Guard configuration"
echo "check  - generates a non-zero return code if Observer is not running locally with ping delay of <100 seconds"
echo
}

function get_active_target_db()
{
echo -e "${CONFIG}\nshow observers;" | dgmgrl -silent / | awk '/Active Target:/{print $NF}'
}


function set_master_observer()
{
ACTIVE_TARGET_SID=$(get_active_target_db | tr 'a-z' 'A-Z')
LOCAL_SID=$(echo $ORACLE_SID | tr 'a-z' 'A-Z')
if [[ ! -z "${ACTIVE_TARGET_SID}"
     && "${ACTIVE_TARGET_SID}" == "${LOCAL_SID}" ]];
then
   THIS_OBSERVER=$(get_observer)
   THIS_OBSERVER_TYPE=$(get_observer_type ${THIS_OBSERVER})
   if [[ "${THIS_OBSERVER_TYPE}" == "Backup" ]];
   then
     HOSTNAME=$(hostname)
     echo "Becoming Master Observer"
     echo -e "${CONFIG}\nset masterobserverhosts to ${HOSTNAME};" | dgmgrl -silent /
   fi
fi
}

function stop_named_observer()
{
OBSERVER=$1
echo "Stopping Observer ${OBSERVER}"
echo -e "${CONFIG}\nconnect /\nstop observer ${OBSERVER};" | dgmgrl -silent
}

function get_backup_observers()
{
echo -e "${CONFIG}\nshow observers;"  | dgmgrl -silent / | grep -E "Observer \".+\" - Backup" | awk '{print $2}'
}

function stop_backup_observers()
{
for BACKUP_OBSERVER in $(get_backup_observers)
   {
   stop_named_observer ${BACKUP_OBSERVER}
   }
}

function get_observer_type()
{
OBSERVER=$1
 echo -e "${CONFIG}\nshow observers;"  | dgmgrl -silent / | grep -E "${OBSERVER}" | awk '{print $NF}'
}

function get_observer()
{
echo -e "${CONFIG}\nshow observers;"  | dgmgrl -silent / | grep -E -B3 "Host Name:\\s+$(hostname)$" | grep "Observer \"$(hostname)" | awk '{print $2}'
}

function get_cwcn()
{
echo -e "${CONFIG}\nshow observers;" | dgmgrl -silent | grep "Submitted command \"SHOW OBSERVER\" using connect identifier" | awk '{print $NF}'
}

function status_observer()
{
echo -e "${CONFIG}\nshow observers;" | dgmgrl -silent 
}

function start_observer()
{
THIS_CWCN=$(get_cwcn)
# Check Data Guard does not have any errors before attempting to start
# the Observer
check_data_guard
echo -e "${CONFIG}\nconnect /\nstart observer in background file is ${ORACLE_BASE}/dg_observer/fsfo.dat logfile is ${ORACLE_BASE}/dg_observer/observer.log connect identifier is ${THIS_CWCN};" | dgmgrl -silent
# Allow time for statup attempt
COUNT=1
while (( COUNT<= 100 ));
do
  echo -ne "."
  CHECK=$(check_observer)
  if [[ ${CHECK} -eq 0 ]];
  then 
     break
  fi
  COUNT=$(( COUNT+1 ))
done
echo
# Check if this is the intended site for the master observer 
# and change the type of the observer if it is not currently so
set_master_observer
}

function count_data_guard_errors()
{
echo -e "show configuration;" | dgmgrl -silent / | grep -c ORA-
}


function check_data_guard()
{
COUNT=1
# Loop a few times to allow time for any errors to clear
while (( COUNT <= 60 ));
do
  echo -ne "."
  sleep 1
  CHECK=$(count_data_guard_errors)
  if [[ ${CHECK} -eq 0 ]];
  then
     return
  fi
  COUNT=$(( COUNT+1 ))
done
echo
# Exit with Failure if Data Guard has Errors
# Do not attempt to start the observer
echo -e "show configuration;" | dgmgrl -silent / | grep ORA-
exit 1  
}


function stop_observer()
{
THIS_OBSERVER=$(get_observer)
THIS_OBSERVER_TYPE=$(get_observer_type ${THIS_OBSERVER})
# If stopping the Master Observer, the Backup Observers must be stopped first
if [[ "${THIS_OBSERVER_TYPE}" == "Master" ]];
then
   stop_backup_observers
fi
if [[ ! -z ${THIS_OBSERVER} ]];
then
   stop_named_observer ${THIS_OBSERVER}
fi
}

function check_observer()
{
THIS_OBSERVER=$(get_observer)
# Return error code if no observer found on this host
if [[ -z "${THIS_OBSERVER}" ]];
then
   echo 1
else
# When we check the observer we expect to find two 1 or 2 digit numbers
# corresponding to the Ping Times to Primary and Standby.
# Anything else is considered to be an error.
   echo -e "${CONFIG}\nshow observers;"  | dgmgrl -silent / | grep -A4 "Observer ${THIS_OBSERVER}" | grep "Last Ping to" | awk '{print $5}' | grep -c -E "^[[:digit:]]{1,2}$" | grep -q 2
   echo $?
fi
}

case $1 in
'start')
start_observer
;;
'stop')
stop_observer
;;
'clean')
stop_observer;
start_observer;
;;
'status')
status_observer;
;;
'check')
RC=$(check_observer)
exit $RC
;;
*)
usage;
;;
esac

exit 0
