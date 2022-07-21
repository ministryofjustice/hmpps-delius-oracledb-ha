#!/bin/bash
# Get all the Observer Host Names

OBSERVER_CONFIG_FILE=$1

. ~/.bash_profile

dgmgrl /<<EODG
set ObserverConfigFile=${OBSERVER_CONFIG_FILE};
show observers;
exit;
EODG