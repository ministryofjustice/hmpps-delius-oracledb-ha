#!/bin/bash
# Get all the Observer Host Names

OBSERVER_CONFIG_FILE=$1

. ~/.bash_profile

dgmgrl /<<EODG | awk '/^Observer /{OBSERVER=$2; TYPE=$NF};/Host Name:/{print OBSERVER,TYPE,$3}'
set ObserverConfigFile=${OBSERVER_CONFIG_FILE};
show observers;
EODG