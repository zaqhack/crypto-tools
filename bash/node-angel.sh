#!/bin/bash
# Khala node "Angel Process" to make sure the node is behaving properly.
# zaqhack - Hologram on Phala discord - Zack Stone on YouTube

# Constants - change them to meet your environment and/or tastes
#
# Directory requirements. Personally, I set this up with an Ansible role.
#     console.js - the javascript console for Phala
#     docker-compose.yml - A list of containers that includes khala-node
#     .env - Variables to manage docker-compose

INSTALLDIR=/opt/phala

# Optional - push the findings to InfluxDB so you can graph them, later.
#     Put IP:PORT here if you want to use this feature or "no" for disabled.
INFLUXDBHOST=no
#     Name of the database?
INFLUXDBNAME=homebrew

# "source" is a somewhat dangerous script option. Familiarize yourself
# with the risks of using it if you have come this far. #Quick&Dirty
source ${INSTALLDIR}/node-angel.dat

# This counts how many things go wrong along the way. We need to
# overwrite the last run's count which we got from the "source."
REBOOT_FLAG=0
# Similarly, let's set an error condition if we can't get peer data.
KHALA_PEERS=-1
KUSAMA_PEERS=-1

# Gather current state information
NODE_UPTIME=$(ps -eo etimes,comm | grep khala-node | grep -o '[0-9]\+')
KHALA_QUERY=$(node $INSTALLDIR/console.js --substrate-ws-endpoint "wss://khala.api.onfinality.io/public-ws" chain sync-state)
CURRENT_KHALA_HEIGHT=$(echo ${KHALA_QUERY} | awk -F "," '{print $5}' | sed 's/ currentBlock: //g')
CURRENT_KUSAMA_HEIGHT=$(node $INSTALLDIR/console.js --substrate-ws-endpoint "wss://pub.elara.patract.io/kusama" chain sync-state | awk -F " " '/currentBlock/ {print $NF}' | sed 's/,//g')
KHALA_PEERS=$(curl -sH "Content-Type: application/json" -d '{"id":1, "jsonrpc":"2.0", "method": "system_peers", "params":[]}' http://localhost:9933 | jq '.result' | jq length)
KUSAMA_PEERS=$(curl -sH "Content-Type: application/json" -d '{"id":1, "jsonrpc":"2.0", "method": "system_peers", "params":[]}' http://localhost:9934 | jq '.result' | jq length)

# Calculate problem outcomes
TEST=$(ps -eo etimes,comm | grep khala-node | wc -l)
if [ "${TEST}" == "0" ]
then
        # khala-node is not running!
        REBOOT_FLAG=-1
        NODE_UPTIME=-1
        if [ "$1" != "cron" ]
        then
                echo "RBF=${REBOOT_FLAG}: Node is not running!!!"
        fi
        CURRENTDIR=`pwd`
        cd ${INSTALLDIR}
        /usr/bin/docker stop phala-node
        /usr/local/bin/docker-compose up -d phala-node
        cd ${CURRENTDIR}
else
        # The peers threshold here is set to 8.
        # If it falls below that, restart node.
        TOTAL_PEERS=$(( ${KUSAMA_PEERS}+${KHALA_PEERS} ))
        if [ "${TOTAL_PEERS}" -lt "8" ]
        then
                ((REBOOT_FLAG++))
                echo "RBF=${REBOOT_FLAG}: Too few peers ..."
        fi

        # Is the node stuck on processing new Khala blocks?
        # If so, restart the node.
        # The span of detection is the CRON timer. I set mine to */5 * * * *
        if [ "${CURRENT_KHALA_HEIGHT}" == "${LAST_KHALA_HEIGHT}" ]
        then
                ((REBOOT_FLAG++))
                echo "RBF=${REBOOT_FLAG}: Khala block height not updated in over 5 minutes ..."
        fi

        # If the node stuck on processing new Kusama blocks?
        # If so, restart the node.
        # The span of detection is the CRON timer. I set mine to */5 * * * *
        if [ "${CURRENT_KUSAMA_HEIGHT}" == "${LAST_KUSAMA_HEIGHT}" ]
        then
                ((REBOOT_FLAG++))
                echo "RBF=${REBOOT_FLAG}: Kusama block height not updated in over 5 minutes ..."
        fi
fi

# Save it all back to the node-angel.dat file
echo NODE_UPTIME=${NODE_UPTIME} > ${INSTALLDIR}/node-angel.dat
echo REBOOT_FLAG=${REBOOT_FLAG} >> ${INSTALLDIR}/node-angel.dat
echo LAST_KUSAMA_HEIGHT=${CURRENT_KUSAMA_HEIGHT} >> ${INSTALLDIR}/node-angel.dat
echo LAST_KHALA_HEIGHT=${CURRENT_KHALA_HEIGHT} >> ${INSTALLDIR}/node-angel.dat
echo KUSAMA_PEERS=${KUSAMA_PEERS} >> ${INSTALLDIR}/node-angel.dat
echo KHALA_PEERS=${KHALA_PEERS} >> ${INSTALLDIR}/node-angel.dat

# Do we have a valid InfluxDB host?
if [ "${INFLUXDBHOST}" != "no" ]
then
        # Send our findings to InfluxDB
        H=`hostname`
        echo "khala_node_uptime,host=${H} value=${NODE_UPTIME}" > /tmp/influxdbpayload.tmp
        echo "khala_node_kusama_height,host=${H} value=${CURRENT_KUSAMA_HEIGHT}" >> /tmp/influxdbpayload.tmp
        echo "khala_node_kusama_peers,host=${H} value=${KUSAMA_PEERS}" >> /tmp/influxdbpayload.tmp
        echo "khala_node_khala_height,host=${H} value=${CURRENT_KHALA_HEIGHT}" >> /tmp/influxdbpayload.tmp
        echo "khala_node_khala_peers,host=${H} value=${KHALA_PEERS}" >> /tmp/influxdbpayload.tmp
        if [ "${NODE_UPTIME}" -gt 600 ] && [ "${REBOOT_FLAG}" -gt 0 ]
        then
                echo "khala_node_reboot,host=${H} value=1" >> /tmp/influxdbpayload.tmp
        fi
        curl -i -XPOST "http://${INFLUXDBHOST}/write?db=${INFLUXDBNAME}" --data-binary @/tmp/influxdbpayload.tmp
else
        if [ "$1" != "cron" ]
        then
                echo "InfluxDB skipped."
        fi
fi

# Is this run from a cron job?
if [ "$1" != "cron" ]
then
        # Show what we picked up to stdout
        echo Node uptime: ${NODE_UPTIME}
        echo Total REBOOT_FLAG: ${REBOOT_FLAG}
        echo Kusama - Blocks: ${CURRENT_KUSAMA_HEIGHT}  Peers: ${KUSAMA_PEERS}
        echo Khala  - Blocks: ${CURRENT_KHALA_HEIGHT}  Peers: ${KHALA_PEERS}
fi

# Has the node been running long enough for us to pass judgment
# on it's health? I chose 10 minutes. Adjust as you see fit.
if [ ${NODE_UPTIME} -gt 600 ]
then
        # Restart the node if we counted more than one reason above.
        if [ ${REBOOT_FLAG} -gt 0 ]
        then
                CURRENTDIR=`pwd`
                cd ${INSTALLDIR}
                /usr/bin/docker stop phala-node
                /usr/bin/docker-compose up -d phala-node
                cd ${CURRENTDIR}
        fi
fi
