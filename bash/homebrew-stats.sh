#!/bin/bash
# Performance tracking for this script within itself
PERF_START=$(echo $EPOCHREALTIME | sed 's/\.//')

# The following configuration file must contain $H (hostnmae), $FS_Tracked, $MEM_TRACKED, $PROC_TRACKED,
# $TF (the temp file for building the payload), and the $INFLUXDB and $DATABASE connection strings.
source homebrew.env

# Report CPU LoadAverage
CPU=$(cat /proc/loadavg)
echo $CPU | awk -v H="${H}" '{ print "load_avg_1m,host=" H " value=" $1 }' >> ${TF}
echo $CPU | awk -v H="${H}" '{ print "load_avg_5m,host=" H " value=" $2 }' >> ${TF}
echo $CPU | awk -v H="${H}" '{ print "load_avg_15m,host=" H " value=" $3 }' >> ${TF}
echo $CPU | awk '{ print $4 }' | awk -F '/' \
                -v H="${H}" '{ print "load_avg_threads,host=" H " value=" $1 }' >> ${TF}
echo $CPU | awk '{ print $4 }' | awk -F '/' \
                -v H="${H}" '{ print "load_avg_processes,host=" H " value=" $2 }' >> ${TF}

# Report file system usage
for D in ${FS_TRACKED[@]};
do
        FS=$(df | grep "${D}")
        echo $FS | awk -v LABEL="fs_capacity,host=${H},device=${D} value=" '{ print LABEL $2 }' >> ${TF}
        echo $FS | awk -v LABEL="fs_used,host=${H},device=${D} value=" '{ print LABEL $3 }' >> ${TF}
        echo $FS | awk -v LABEL="fs_available,host=${H},device=${D} value=" '{ print LABEL $4 }' >> ${TF}
done

# Report about operating memory
for M in ${MEM_TRACKED[@]};
do
        grep -i ${M} /proc/meminfo | awk -v LABEL="mem_${M},host=${H} value=" '{ print LABEL $2 }' >> ${TF}
done

# Report about running processes
PSR="$(ps -eo etimes,c,rss,vsz,comm)"
for P in ${PROC_TRACKED[@]};
do
        THREADS=echo "$PSR" | grep -i ${P} | wc -l
        if [ "$THREADS" -eq 0 ]
        then
                echo "Process ${P} not found among active processes."
        elseif [ "$THREADS" -eq 1 ]
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_etimes_${P},host=${H} value=" '{ print LABEL $1 }' >> ${TF}
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_cpu_${P},host=${H} value=" '{ print LABEL $2 }' >> ${TF}
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_activemem_${P},host=${H} value=" '{ print LABEL $3 }' >> ${TF}
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_virtualmem_${P},host=${H} value=" '{ print LABEL $4 }' >> ${TF}
        elseif [ "$THREADS" -gt 1 ]
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_etimes_${P},host=${H} value=" '{ SUM+=$1 }END{ print LABEL SUM }' >> ${TF}
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_cpu_${P},host=${H} value=" '{ SUM+=$2 }END{ print LABEL SUM }' >> ${TF}
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_activemem_${P},host=${H} value=" '{ SUM+=$3 }END{ print LABEL SUM }' >> ${TF}
                echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_virtualmem_${P},host=${H} value=" '{ SUM+=$4 }END{ print LABEL SUM }' >> ${TF}
                echo "proc_threads_${P},host=${H} value=${THREADS}" >> ${TF}
        fi
done

if [ "$PERF_START" != "" ]; then
        echo "gather_stats_musec,host=${H} value="$(( $(echo $EPOCHREALTIME | sed 's/\.//') - ${PERF_START} )) | tee -a ${TF}
fi

curl -i -XPOST "http://${INFLUXDB}/write?db=${DATABASE}" --data-binary @${TF}

if [ "$PERF_START" != "" ]; then
        echo
        echo $(( $(echo $EPOCHREALTIME | sed 's/\.//') - ${PERF_START} )) microseconds to run this script.
fi
