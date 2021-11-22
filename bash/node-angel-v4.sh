#!/bin/bash
# Khala node "Angel Process" to make sure the node is behaving properly.
# zaqhack - Hologram on Phala discord - Zack Stone on YouTube
# Version 03

# Constants - change them to meet your environment and/or tastes
DEBUG=0    # Set to 1 to enable

# Directory requirements. Personally, I set this up with an Ansible role.
#     console.js - the javascript console for Phala
#     docker-compose.yml - A list of containers that includes phala-node
#     .env - Variables to manage docker-compose
INSTALLDIR=/opt/phala

# If this is part of a cron job, we'll tone down the stdout messaging.
if [ "$1" == "cron" ]; then CRONJOB="yes";
                       else CRONJOB="no"; fi

# Optional - push the findings to InfluxDB so you can graph them, later.
#     Put IP:PORT here if you want to use this feature or "no" for disabled.
INFLUXDBHOST=no
INFLUXDBNAME=homebrew             # Name of the database
TF=/tmp/influxdb-payload.tmp      # Temp file for database inputs

# Process arrays to make the checks interative/recycle-able
K=("KHALA_CURRENT" "KHALA_HEIGHT" "KUSAMA_CURRENT" "KUSAMA_HEIGHT")

# This counts how many things go wrong along the way.
RESTART_FLAG=0

function _restart_container {
        # Perform restart
        local CURRENTDIR=`pwd`
        cd ${INSTALLDIR}
        /usr/bin/docker stop "phala-node"
        if [ "$1" == "pull" ]
        then
                /usr/local/bin/docker-compose pull
        fi
        /usr/local/bin/docker-compose up -d phala-node
        cd ${CURRENTDIR}
}

function _is_running {
        # Check if the container is running
        J=$(docker inspect -f '{{json .State}}' "phala-node")
        S=$(echo $J | jq '.Status')
        P=$(echo $J | jq '.Pid')
        U=$(ps -eo etimes,pid | grep ${P} | grep -o '[0-9]\+' | head -1)
        if [[ "${S}" != *"running"* ]]
        then
                # Container is not running!
                if [ "$CRONJOB" == "no" ]; then echo "Phala-node is not running!!!" ;fi
                RESTART_FLAG=$(( ${RESTART_FLAG} + 1 ))
                _restart_container
                U=0
        else
                # Container is running.
                if [ "$CRONJOB" == "no" ]; then echo "Phala-node is running." ;fi
        fi
}

function _check_logs {
        # Has it been over 60 seconds since the last log entry?
        LASTLOG="$(/usr/bin/docker logs --tail 1 phala-node 2>&1)"
        TIMESTAMP=$(echo "${LASTLOG}" | awk '{ print $1 " " $2}' )
        TZADJUST=$(( 8 * 60 * 60 )) # Adjust for 8-hour timezone difference (Hong Kong)
        LASTLOG_EPOCH=$(( $(date --date="${TIMESTAMP}" +%s) + ${TZADJUST} ))
        TIMEDIFF=$(( $EPOCHSECONDS - $LASTLOG_EPOCH ))
        if [ "${TIMEDIFF}" -gt 60 ]; then
                if [ "$CRONJOB" == "no" ]; then echo "Logs are stale; assuming process frozen." ;fi
                RESTART_FLAG=$(( ${RESTART_FLAG} + 2 ))
                _restart_container
        fi
}

function _blockchain_check {
        RESTART="no"
        source .node.dat
        rm .node.dat
        touch .node.dat
        for METRIC in ${K[@]}; do
                # Was getting too deep into the indirect references and getting errors
                # This pulls out one level of recursion/indirection:
                Z="LAST_${METRIC}"; T="TIME_${METRIC}"

                if [ $DEBUG -gt 0 ]; then  # Some debug things for indirect references
                        echo "Current metric = ${METRIC} = $(eval "echo \$${METRIC}")"
                        echo "Last metric = $(eval "echo \$${Z}")"
                        echo "Metric timestamp = $(eval "echo \$${T}")"
                fi

                # Is the current metric the same as the one we saved in the file last time?
                if [[ $(eval "echo \$${METRIC}") -eq $(eval "echo \$${Z}") ]]
                then
                        DELTA=$(expr `date +%s` - $(eval "echo \$${T}"))

                        if [ $DEBUG -gt 0 ]; then  # Some more debug info
                                echo "Same value"; echo "Delta seconds = $DELTA"; fi

                        if [ $DELTA -gt 360 ]; then
                                if [ "$CRONJOB" == "no" ]; then
                                        echo "${METRIC} is frozen ... setting restart flag."; fi
                                RESTART="yes"
                        fi
                else
                        if [ $DEBUG -gt 0 ]; then echo "Different value"; fi # Still more Debug

                        let $(eval "echo ${T}")=$(date +%s)
                        let $(eval "echo ${Z}")=$(eval "echo \$${METRIC}")
                fi

                # Add discovered stats to InfluxDB payload
                if [ "${INFLUXDBHOST}" != "no" ]; then
                        LABEL=`echo "${METRIC}" | tr '[:upper:]' '[:lower:]'`
                        echo "khala_node_${LABEL},host=${H} value=$(eval "echo \$${METRIC}")" >> ${TF}
                fi

                # Add this metric to the .(process).dat file
                echo "LAST_${METRIC}=$(eval "echo \$${Z}")" >> .node.dat
                echo "TIME_${METRIC}=$(eval "echo \$${T}")" >> .node.dat
        done

        # Is the process stuck on a particular block? If so, restart.
        if [ "$RESTART" == "yes" ]; then
                RESTART_FLAG=$(( ${RESTART_FLAG} + 4 ))
                _restart_container
        fi
}

if [ "${INFLUXDBHOST}" != "no" ]
then
        # Reset InfluxDB payload file
        touch ${TF}
        rm ${TF}
        touch ${TF}
        H=`hostname`
fi

# Loop through the checks to see if the node is up
_is_running
if [ "${RESTART_FLAG}" -eq 0 ]
then
        _check_logs
        if [ "${RESTART_FLAG}" -eq 0 ]
        then
                L30="$(docker logs --tail 30 phala-node 2>&1)"
                KHALA_CURRENT=$(echo "$L30" | grep Parachain | grep best | tail -n 1 | awk '{ print $12} '| sed 's/#//')
                KHALA_HEIGHT=$(echo "$L30" | grep Parachain | grep best | tail -n 1 | awk '{ print $9} '| sed 's/#//')
                KHALA_PEERS=$(echo "$L30" | grep Parachain | grep best | tail -n 1 | awk '{ print $6} '| sed 's/(//')
                KUSAMA_CURRENT=$(echo "$L30" | grep Relaychain | grep best | tail -n 1 | awk '{ print $12} '| sed 's/#//')
                KUSAMA_HEIGHT=$(echo "$L30" | grep Relaychain | grep best | tail -n 1 | awk '{ print $9} '| sed 's/#//')
                KUSAMA_PEERS=$(echo "$L30" | grep Relaychain | grep best | tail -n 1 | awk '{ print $6} '| sed 's/(//')
                _blockchain_check

                if [ "${RESTART_FLAG}" -eq 0 ]
                then
                        if [ $(($KHALA_PEERS + $KUSAMA_PEERS )) -lt 8 ]
                        then
                                RESTART_FLAG=$(( ${RESTART_FLAG} + 8 ))
                                _restart_container pull
                        fi
                fi
        fi
fi

# Do we have a valid InfluxDB host?
if [ "${INFLUXDBHOST}" != "no" ]
then
        # Ship all findings to InfluxDB
        echo "khala_node_uptime,host=${H} value=${U}" >> ${TF}
        echo "khala_node_khala_peers,host=${H} value=${KHALA_PEERS}" >> ${TF}
        echo "khala_node_kusama_peers,host=${H} value=${KUSAMA_PEERS}" >> ${TF}
        echo "khala_reboot_flags,host=${H} value=${RESTART_FLAG}" >> ${TF}
        curl -i -XPOST "http://${INFLUXDBHOST}/write?db=${INFLUXDBNAME}" --data-binary @${TF}
else
        if [ "$CRONJOB" == "no" ]; then echo "InfluxDB skipped." ;fi
fi
