#!/bin/bash
# Performance tracking for this script within itself
PERF_START=$(echo $EPOCHREALTIME | sed 's/\.//')

# Homebrew system metrics - only gather what we want
# The purpose is to avoid Prometheus, Telegraf, et al

# Hostname that will be tagged in InfluxDB
H=$(hostname)

# Partitions that we are tracking usage on
# These are used for "grep" and have to be unique in "df"
FS_TRACKED=("vda1" "vdb1")

# Similarly, these are the memory stats we're going to report
# These are used for "grep" and have to be unique in "/proc/meminfo"
MEM_TRACKED=("memtotal" "memfree" "swapcached" "swaptotal" "swapfree")

# Finally, these are the processes we're going to track
# These are used for "grep" and have to be unique in "ps"
PROC_TRACKED=("phala-node" )

# Reset the payload file in case it exists
TF="/tmp/influxdb_vitals.tmp"
rm ${TF}
touch ${TF}

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
        echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_etimes_${P},host=${H} value=" '{ print LABEL $1 }' >> ${TF}
        echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_cpu_${P},host=${H} value=" '{ print LABEL $2 }' >> ${TF}
        echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_activemem_${P},host=${H} value=" '{ print LABEL $3 }' >> ${TF}
        echo "$PSR" | grep -i ${P} | awk -v LABEL="proc_virtualmem_${P},host=${H} value=" '{ print LABEL $4 }' >> ${TF}
done

if [ "$PERF_START" != "" ]; then
        echo "gather_stats_musec,host=${H} value="$(( $(echo $EPOCHREALTIME | sed 's/\.//') - ${PERF_START} )) | tee -a ${TF}
fi

curl -i -XPOST "http://(INFLUXDB)/write?db=homebrew" --data-binary @${TF}

if [ "$PERF_START" != "" ]; then
        echo
        echo $(( $(echo $EPOCHREALTIME | sed 's/\.//') - ${PERF_START} )) microseconds to run this script.
fi
