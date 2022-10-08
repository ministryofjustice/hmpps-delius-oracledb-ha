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

. ~oracle/.bash_profile

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
# Active standby database is preceeded by a *
dgmgrl / "show configuration;" | grep -- "- (\*) Physical standby database" | awk '{print $1}'
}

function get_non_active_target_db()
{
# Any other standby database is not preceeded by a *
dgmgrl / "show configuration;" | grep -- "- Physical standby database" | awk '{print $1}'
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


function assume_master_observer_role()
{
# Set Any Observer on this Host to be the Master (Arbitrarily the First)
THIS_OBSERVER=$(get_observers | awk '{print $1}')
THIS_OBSERVER_TYPE=$(get_observer_type ${THIS_OBSERVER})
if [[ "${THIS_OBSERVER_TYPE}" == "Backup" ]];
then
   HOSTNAME=$(hostname)
   echo "Becoming Master Observer"
   set_master_observer_host ${HOSTNAME}
fi
}


function set_master_observer()
{
ACTIVE_TARGET_SID=$(get_active_target_db | tr 'a-z' 'A-Z')
NON_ACTIVE_TARGET_SID=$(get_non_active_target_db | tr 'a-z' 'A-Z')
LOCAL_SID=$(echo $ORACLE_SID | tr 'a-z' 'A-Z')
# If the Non-Active Target Database is running on this Host, make this the Master Observer
# i.e. Run the Master Observer on 3rd site which is neither Primary nor Standby
# (This is recommended practice)
if [[ ! -z "${NON_ACTIVE_TARGET_SID}"
     && "${NON_ACTIVE_TARGET_SID}" == "${LOCAL_SID}" ]];
then
   assume_master_observer_role
# If there is no Non-Active Target Database (i.e. there is only one standby),
# then use the Standby site as master
elif [[ ! -z "${ACTIVE_TARGET_SID}"
     &&   -z "${NON_ACTIVE_TARGET_SID}"
     && "${ACTIVE_TARGET_SID}" == "${LOCAL_SID}" ]];
then
   assume_master_observer_role
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
# Try relocating master observer to one of the other hosts until it succeeds
for OBSERVER_HOST in $(get_backup_observer_hosts)
do
   if [[ "$HOSTNAME" != "${OBSERVER_HOST}" ]]
   then
      set_master_observer_host ${OBSERVER_HOST}
      [[ $? == 0 ]] && break
      echo "Relocation failed"
   fi
done  
poll_for_master_observer_host "${OBSERVER_HOST}" 
} 


function get_observer_type()
{
OBSERVER=$1
echo -e "${CONFIG}\nshow observers;"  | dgmgrl -silent / | grep -E "${OBSERVER}" | awk '{print $NF}'
}

function get_observers()
{
# Return tab delimited list of the names of all Observers running on this host (normally expect 0 or 1, but there can be up to 3).
# Observer name may under certain conditions (such as during patching) be suffixed with the version in parenthesis - this information should be excluded
# Note that the case of the hostname within the Observer name may change from that which was specified, so use case insensitive search
dgmgrl -silent / "show observer;" | grep -E -B3 "Host Name:\\s+$(hostname)$" | grep -i "Observer \"$(hostname)" | awk '{print $2}' | awk -F \( '{print $1}' | paste - -
}

function get_cwcn()
{
echo -e "${CONFIG}\nshow observers;" | dgmgrl -silent / | grep "Submitted command \"SHOW OBSERVER\" using connect identifier" | awk '{print $NF}'
}

function status_observer()
{
echo -e "${CONFIG}\nshow observers;" | dgmgrl -silent /
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

function stop_defunct_observer()
{
# It is possible that up to 3 observers may run on a single node
# This is not desired and any defunct observers no longer
# able to communicate with the primary and target databases should be stopped
BACKUP_OBSERVER_COUNT=$(dgmgrl -silent / "show observer" | grep -A2 -E -e "$(hostname)\"" | grep -c -- "- Backup")
MASTER_OBSERVER_COUNT=$(dgmgrl -silent / "show observer" | grep -A2 -E -e "$(hostname)\"" | grep -c -- "- Master")
if [[ $BACKUP_OBSERVER_COUNT -eq 1 && $MASTER_OBSERVER_COUNT -eq 1 ]]
then  
   # Stop Backup Observer as Master is running on this Host
    DEFUNCT_OBSERVER_NAME=$(dgmgrl -silent / "show observer" | grep -A3 -E -e "$(hostname)\"" | grep -- "- Backup" | awk '{print $2}')
    stop_observer ${DEFUNCT_OBSERVER_NAME}
fi
if [[ $BACKUP_OBSERVER_COUNT -gt 1 ]]
then
   # More than one Backup observer found. Find and stop the defunct one.
   DEFUNCT_OBSERVER=$(dgmgrl -silent / "show observer" | grep -A3 -E -e "$(hostname)\"" | grep -A4 -- "- Backup" | awk '/Observer/{OBSERVER=$2}/(unknown)/{print OBSERVER}' | uniq -c)
   DEFUNCT_PING_COUNT=$(echo $DEFUNCT_OBSERVER | awk '{print $1}')
   DEFUNCT_OBSERVER_NAME=$(echo $DEFUNCT_OBSERVER | awk '{print $2}')
   if [[ ${DEFUNCT_PING_COUNT} -eq 1 && ! -z ${DEFUNCT_OBSERVER_NAME} ]];
   then
      # Stop observer with Unknown Ping Times
      stop_observer ${DEFUNCT_OBSERVER_NAME}
   else
      # Both observers have valid Ping Times - Stop the one with the Longest Aggregate (Primary+Target) Ping Time
      LONGEST_PING=$(dgmgrl -silent / "show observer" | grep -A3 -E -e "$(hostname)\"" | grep -A4 -- "- Backup" | awk 'BEGIN{SUM=0}/Observer/{OBSERVER=$2}/Last Ping/{SUM+=$5}/--/{print SUM,OBSERVER; SUM=0}END{print SUM,OBSERVER}' | sort -n -k1 | tail -1)
      DEFUNCT_OBSERVER_NAME=$(echo $LONGEST_PING | awk '{print $2}')
      stop_observer ${DEFUNCT_OBSERVER_NAME}
   fi
fi
}


function start_observer()
{
EXISTING_OBSERVER_ERROR=$(check_observer)
# An non-zero code will be returned if there is no existing observer or it has errors.   In this case start an Observer.
if [[ "${EXISTING_OBSERVER_ERROR}" -gt 0 ]];
then
      # Stop any existing Observers on this host as they are in an error state
      # and we want them to be restarted
      for BAD_OBSERVER in $(get_observers)
      do
         stop_named_observer "${BAD_OBSERVER}"
      done
      THIS_CWCN=$(get_cwcn)
      # Check Data Guard does not have any errors before attempting to start
      # the Observer
      check_data_guard
      # As of Oracle 19.16 the Observer will start with "noname" by default, which prevents multiple Observers starting
      # as they will all have the same name.  As a workaround use the hostname suffixed by 1 which replicates the
      # behaviour of earlier versions.
      echo -e "${CONFIG}\nconnect /\nstart observer \"$(hostname)1\" in background file is ${ORACLE_BASE}/dg_observer/fsfo.dat logfile is ${ORACLE_BASE}/dg_observer/observer.log connect identifier is ${THIS_CWCN};" | dgmgrl -silent
      poll_for_observer
      echo
      # Check the Active Target database is set to the preferred database
      set_preferred_active_target_database
      # Check for defunct Observers on this host and stop them
      stop_defunct_observer
      echo
      # Check if this is the intended site for the master observer 
      # and change the type of the observer if it is not currently so
      set_master_observer
      echo
else
    echo "Observer already started"
fi
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
# Stop all Observers running on this host
for THIS_OBSERVER in $(get_observers)
do
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
done
}

function get_fast_start_failover()
{
# Get whether FSFO is Enabled (Enabled and Observe-Only are treated as equivalent)
dgmgrl / "show configuration" | awk '/Fast-Start Failover:/{print $3}'
}


function check_observer()
{
# Check if FSFO is Enabled
FSFO_STATUS=$(get_fast_start_failover)
if [[ "${FSFO_STATUS}" == "Disabled" ]];
then
   # If FSFO is Disabled then the Observer will only be pinging the Primary  
   PING_TARGETS=1
else  
   # If FSFO is Enabled then the Observer will ping both Primary and Active Target
   PING_TARGETS=2
fi
# Return success code 0 if an observer is running with a sensible ping time (less than 100 seconds)
ALL_OBSERVERS=$(get_observers)
# Return error code if no observer found on this host
if [[ -z "${ALL_OBSERVERS}" ]];
then
   echo 1
else
# When we check the observer we expect to find two 1 or 2 digit numbers
# corresponding to the Ping Times to Primary (and Active Target Standby if FSFO Enabled).
# Anything else is considered to be an error.
for THIS_OBSERVER in $(echo ${ALL_OBSERVERS})
do
   sleep 1
   # Loop through all the Observers (normally there will just be one).   Only one needs to be operation to return a success code.
   echo -e "${CONFIG}\nshow observers;"  | dgmgrl -silent / | grep -A4 "Observer ${THIS_OBSERVER}" | grep "Last Ping to" | awk '{print $5}' | grep -c -E "^[[:digit:]]{1,2}$" | grep -q ${PING_TARGETS}
   if [[ $? -eq 0 ]];
   then
      echo 0
      return
   fi
done
echo 1
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
