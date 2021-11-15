
#!/bin/bash
# Khala node "Angel Process" to make sure the node is behaving properly.
# zaqhack - Hologram on Phala discord - Zack Stone on YouTube
# Version 03

# Constants - change them to meet your environment and/or tastes
DEBUG=0    # Set to 1 to enable

# Directory requirements. Personally, I set this up with an Ansible role.
#     console.js - the javascript console for Phala
#     docker-compose.yml - A list of containers that includes khala-node
#     .env - Variables to manage docker-compose
INSTALLDIR=/opt/phala

# If this is part of a cron job, we'll tone down the stdout messaging.
if [ "$1" == "cron" ]; then CRONJOB="yes";
                       else CRONJOB="no"; fi

# Optional - push the findings to InfluxDB so you can graph them, later.
#     Put IP:PORT here if you want to use this feature or "no" for disabled.
INFLUXDBHOST=no
INFLUXDBNAME=homebrew    # Name of the database

# Process arrays to make the checks interative/recycle-able
PRB_PROCESSES=("fetch" "lifecycle" "trade" "monitor")
K=("KHALA_CURRENT" "KHALA_HEIGHT" "KUSAMA_CURRENT" "KUSAMA_HEIGHT")

# This counts how many things go wrong along the way.
RESTART_FLAGS=""

function _restart_container {
        # Perform restart
        local CURRENTDIR=`pwd`
        cd ${INSTALLDIR}
        /usr/bin/docker stop "phala_${1}_1"
        /usr/local/bin/docker-compose up -d ${1}
        cd ${CURRENTDIR}

        # Add container name to RESTART_FLAGS.
        if [ ${#RESTART_FLAGS} -lt 2 ]
        then
                RESTART_FLAGS=${RESTART_FLAGS}+", ${1}"
        else
                RESTART_FLAGS=${RESTART_FLAGS}+"${1}"
        fi
}

function _is_running {
        # Check if the container is running
        J=$(docker inspect -f '{{json .State}}' "phala_${1}_1")
        S=$(echo $J | jq '.Status')
        P=$(echo $J | jq '.Pid')
        U=$(ps -eo etimes,pid | grep ${P} | grep -o '[0-9]\+' | head -1)
        if [[ "${S}" != *"running"* ]]
        then
                # Container is not running!
                if [ "$CRONJOB" == "no" ]; then echo "${1} is not running!!!" ;fi
                IS_RUNNING="no"
                _restart_container "${1}"
                U=0
        else 
                # Container is running.
                if [ "$CRONJOB" == "no" ]; then echo "${1} is running." ;fi
                IS_RUNNING="yes"
        fi

}

function _check_logs {
        # Do the words "FATAL ERROR" appear in the last 30 lines
        # of the process log? If so, restart process

        PANIC=$(/usr/bin/docker logs --tail 30 "phala_${1}_1" | grep -i fatal | wc -l)
        if [ "${PANIC}" -gt 0 ]
        then
                # Is this run from a cron job?
                if [ "$CRONJOB" == "no" ]; then echo "Process ${1} log shows recent \'fatal error\' messages."; fi
                _restart_container "${1}"
        fi
}

function _blockchain_check {
        RESTART="no"
        source .${X}.dat
        rm .${X}.dat
        touch .${X}.dat
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
                        echo "phala_${X}_${LABEL},host=${H} value=$(eval "echo \$${METRIC}")" >> /tmp/influxdbpayload.tmp    
                fi

                # Add this metric to the .(process).dat file
                echo "LAST_${METRIC}=$(eval "echo \$${Z}")" >> .${X}.dat
                echo "TIME_${METRIC}=$(eval "echo \$${T}")" >> .${X}.dat
        done

        # Is the process stuck on a particular block? If so, restart.
        if [ "$RESTART" == "yes" ]; then _restart_container ${X}; fi
}

if [ "${INFLUXDBHOST}" != "no" ]
then
        # Reset InfluxDB payload file
        touch /tmp/influxdbpayload.tmp
        rm /tmp/influxdbpayload.tmp./
        touch /tmp/influxdbpayload.tmp
        H=`hostname`
fi

# Loop through the checks for each process
for X in ${PRB_PROCESSES[@]};
do
        _is_running "${X}"
        if [ "$IS_RUNNING" == "yes" ]
        then
                _check_logs "${X}"
                if [ "${PANIC}" -eq 0 ]
                then
                        case "$X" in
                                fetch)
                                        J=$(docker logs --tail 100 phala_fetch_1 | grep "Saved dryCache" | grep -v ":-1," | tail -1)
                                        KHALA_CURRENT=$(echo ${J} | jq '.paraStartBlock')
                                        KHALA_HEIGHT=$(echo ${J} | jq '.paraStopBlock')
                                        KUSAMA_CURRENT=$(echo ${J} | jq '.parentStartBlock')
                                        KUSAMA_HEIGHT=$(echo ${J} | jq '.parentStopBlock')
                                        _blockchain_check
                                        ;;

                                lifecycle)
                                        J=$(docker logs --tail 30 phala_lifecycle_1 | grep fetcherStateUpdate | tail -1)
                                        KHALA_CURRENT=$(echo ${J} | jq '.content.fetcherStateUpdate.paraBlobHeight')
                                        KHALA_HEIGHT=$(echo ${J} | jq '.content.fetcherStateUpdate.paraKnownHeight')
                                        KUSAMA_CURRENT=$(echo ${J} | jq '.content.fetcherStateUpdate.parentBlobHeight')
                                        KUSAMA_HEIGHT=$(echo ${J} | jq '.content.fetcherStateUpdate.parentKnownHeight')
                                        _blockchain_check
                                        ;;

                        esac
                fi

                # Add discovered stats to InfluxDB payload
                if [ "${INFLUXDBHOST}" != "no" ]
                then
                        echo "phala_${X}_uptime,host=${H} value=${U}" >> /tmp/influxdbpayload.tmp    
                fi
        fi
done

# Do we have a valid InfluxDB host?
if [ "${INFLUXDBHOST}" != "no" ]
then
        # Ship all findings to InfluxDB
        if [ "${#RESTART_FLAGS}" -gt 2 ]
        then
                echo "phala_reboot_flags,host=${H} value=${RESTART_FLAGS}" >> /tmp/influxdbpayload.tmp
        fi
        curl -i -XPOST "http://${INFLUXDBHOST}/write?db=${INFLUXDBNAME}" --data-binary @/tmp/influxdbpayload.tmp
else
        if [ "$CRONJOB" == "no" ]; then echo "InfluxDB skipped." ;fi
fi
