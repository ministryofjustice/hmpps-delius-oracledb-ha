#!/bin/bash

# Detect missing dataguard configuration on primary

. ~/.bash_profile

dgmgrl <<EOF | grep ORA-16532
connect /
show configuration;
EXIT
EOF

# Do not use grep return code
exit 0