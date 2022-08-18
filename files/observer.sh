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

DEBUG=TRUE


if [[ "$DEBUG" == "TRUE" ]];
then
   exec 
   set -x
   date >> ${ORACLE_BASE}/dg_observer/observer_sh.log
   exec >> ${ORACLE_BASE}/dg_observer/observer_sh.log
   exec 2>&1
fi

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

function get_preferred_active_target_database()
{
echo "show fast_start failover" | dgmgrl -silent / | grep "Potential Targets:" | awk '{print $NF}' | sed 's/"//g' | cut -d, -f1 
}

function is_active_target_database_ready()
{
ACTIVE_TARGET_DB=$1
# Return 1 if the required Target database is Ready to be the Active Target
echo "show database ${ACTIVE_TARGET_DB}" | dgmgrl -silent / | grep -A10 "PHYSICAL STANDBY" | grep -c "SUCCESS"
}

function poll_for_target_readiness()
{
# Wait for Target Database to become Ready to be Active Target
COUNT=1
while (( COUNT<= 100 ));
do
  echo -ne "."
  CHECK=$(is_active_target_database_ready)
  if [[ ${CHECK} -eq 1 ]];
  then 
     break
  fi
  COUNT=$(( COUNT+1 ))
done
echo "NOT READY"
}


function is_preferred_active_target_host()
{
PREFERRED_ACTIVE_TARGET_DATABASE=$(get_preferred_active_target_database)
# Returns 1 if the preferred active target database is running on this host
# (Target Databases are listed in order of preference in the Potential Targets - FastStartFailoverTargets parameter)
echo "${PREFERRED_ACTIVE_TARGET_DATABASE}" | grep -ic "^${ORACLE_SID}$"
}

function set_preferred_active_target_database()
{
ACTIVE_TARGET_DATABASE=$(get_active_target_db)
PREFERRED_ACTIVE_TARGET_DATABASE=$(get_preferred_active_target_database)
if [[ "${ACTIVE_TARGET_DATABASE}" != "${PREFERRED_ACTIVE_TARGET_DATABASE}" ]];
then
   echo "Preferred Active Target Database is ${PREFERRED_ACTIVE_TARGET_DATABASE} but current Active Target Database is ${ACTIVE_TARGET_DATABASE}"
   # The current Active Target Database is not the Preferred Active Target Database
   IS_PREFERRED_ACTIVE_TARGET_HOST=$(is_preferred_active_target_host)
   if [[ ${IS_PREFERRED_ACTIVE_TARGET_HOST} -eq 1 ]];
   then
      echo "Preferred Active Target Database is on this host."
      READY=$(poll_for_target_readiness)
      if [[ "${READY}" != "NOT READY" ]];
      then
         echo "Swapping preferred Active Target"
         # This is the host where the active target database should be running
         # (We do not attempt changing target from other hosts as we want to ensure the target host is up)
         echo "set fast_start failover target to ${PREFERRED_ACTIVE_TARGET_DATABASE};" | dgmgrl -silent /
      else
         echo "Preferred Target is not ready - keeping current target"
      fi
   fi
fi
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
     set_master_observer_host ${HOSTNAME}
   fi
fi
}

function stop_named_observer()
{
OBSERVER=$1
echo "Stopping Observer ${OBSERVER}"
echo -e "${CONFIG}\nconnect /\nstop observer ${OBSERVER};" | dgmgrl -silent
}

function count_backup_observers()
{
get_backup_observer_hosts | wc -l
}


function get_master_observer_host()
{
echo -e "show observer;"  | dgmgrl -silent / | grep -A2 -E "Observer \".+\" - Master"  | awk '/Host Name:/{print $NF}'
}


function get_backup_observer_hosts()
{
echo -e "show observer;"  | dgmgrl -silent / | grep -A2 -E "Observer \".+\" - Backup"  | awk '/Host Name:/{print $NF}'
}


function set_master_observer_host()
{
TARGET_HOST=$1
echo "Relocating Master Observer to ${TARGET_HOST}"
echo "set masterobserverhosts to ${TARGET_HOST};" | dgmgrl -silent /
return $?
}

function poll_for_master_observer_host()
{
EXPECTED_HOST=$1
# When Observer is  moved allow a few seconds for placement update
COUNT=1
while (( COUNT<= 100 ));
do
  echo -ne "."
  ACTUAL_HOST=$(get_master_observer_host)
  if [[ "${EXPECTED_HOST}" == "${ACTUAL_HOST}"  ]];
  then 
     break
  fi
  COUNT=$(( COUNT+1 ))
  sleep 1
done
}


function relocate_master_observer()
{
for OBSERVER_HOST in $(get_backup_observer_hosts);
do
   set_master_observer_host ${OBSERVER_HOST}
   [[ $? == 0 ]] && break
   echo "Relocation failed"
done  
poll_for_master_observer_host "${OBSERVER_HOST}" 
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

function poll_for_observer()
{
# When Observer is started or moved allow a few seconds for status update
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
}

function start_observer()
{
THIS_CWCN=$(get_cwcn)
# Check Data Guard does not have any errors before attempting to start
# the Observer
check_data_guard
echo -e "${CONFIG}\nconnect /\nstart observer in background file is ${ORACLE_BASE}/dg_observer/fsfo.dat logfile is ${ORACLE_BASE}/dg_observer/observer.log connect identifier is ${THIS_CWCN};" | dgmgrl -silent
poll_for_observer
echo
# Check the Active Target database is set to the preferred database
set_preferred_active_target_database
poll_for_observer
# Check if this is the intended site for the master observer 
# and change the type of the observer if it is not currently so
set_master_observer
poll_for_observer
echo
RC=$(check_observer)
}

function count_data_guard_errors()
{
# Ignore ORA-16819 (Observer not started) since we are about to start it
# Ignore ORA-16820 (Database not being observed) for same reason
echo -e "show configuration;" | dgmgrl -silent / | grep -v ORA-16819 | grep -v ORA-16820 | grep -c ORA-
}


function check_data_guard()
{
COUNT=1
# Loop a few times to allow time for any errors to clear
while (( COUNT <= 120 ));
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
# If stopping the Master Observer, if any Backup Observers exist then
# one of these must be converted to the Master first 
if [[ "${THIS_OBSERVER_TYPE}" == "Master" ]];
then
   BACKUP_COUNT=$(count_backup_observers)
   if [[ ${BACKUP_COUNT} -gt 0 ]];
   then
      echo "Converting to Backup Observer"
      relocate_master_observer
      THIS_OBSERVER_TYPE=$(get_observer_type ${THIS_OBSERVER})
      if [[ "${THIS_OBSERVER_TYPE}" == "Master" ]];
      then
         if [[ ${BACKUP_COUNT} -gt 0 ]];
         then
            echo "Cannot Stop Master Observer as Backup Observers Still Exist"
            exit 1
         fi
      fi
   else
      echo "No Backup Observers - Stopping Master"
   fi
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
