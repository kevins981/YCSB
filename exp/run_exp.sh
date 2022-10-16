#!/bin/bash


REDIS_DIR="/ssd1/songxin8/thesis/keyValStore/redis/"
REDIS_CLI="${REDIS_DIR}/src/redis-cli"
YCSB_DIR="/ssd1/songxin8/thesis/keyValStore/YCSB/"
WORKLOAD_DIR="${YCSB_DIR}/workloads/" 

RESULT_DIR="/ssd1/songxin8/thesis/keyValStore/YCSB/exp/sweep/"

declare -a WORKLOAD_LIST=("zippydb" "up2x")
#declare -a WORKLOAD_LIST=("zippydb")

clean_up () {
    echo "Cleaning up. Kernel PID is $EXE_PID, numastat PID is $LOG_PID."
    # Perform program exit housekeeping
    kill $LOG_PID
    kill $EXE_PID
    exit
}

clean_cache () { 
  echo "Clearing caches..."
  # clean CPU caches 
  ./tools/clear_cpu_cache
  # clean page cache 
  echo 3 > /proc/sys/vm/drop_caches
}

run_redis () { 
  OUTFILE=$1 #first argument
  WORKLOAD=$2
  NODE=$3

  # change to dir with rdb dumps
  pushd $REDIS_DIR

  # start redis server.
  # there should be a corresponding confg file named redis_${WORKLOAD}.conf
  # e.g. for zippydb, we use redis_zippydb.conf to indicate the RDB file to load.
  /usr/bin/time -v /usr/bin/numactl --membind=${NODE} --cpunodebind=0 \
      -- $REDIS_DIR/src/redis-server $REDIS_DIR/redis_${WORKLOAD}.conf &> ${OUTFILE}_redis_out &

  # PID of time command
  TIME_PID=$! 
  # get PID of actual kernel, which is a child of time. 
  # This PID is needed for the numastat command
  EXE_PID=$(pgrep -P $TIME_PID)

  echo "Waiting 5min for redis to finish loading keys from RDB..."
  # wait for RDB loading to finish. a 40GB redis-server takes ~3min to load from RDB.
  sleep 300

  echo "redis server PID is ${EXE_PID}"
  echo "start" > ${OUTFILE}_numastat 
  while true; do numastat -p $EXE_PID >> ${OUTFILE}_numastat; sleep 5; done &
  LOG_PID=$!

  sleep 10 # wait for redis server to go up

  popd
  # run ycsb load phase
  pushd $YCSB_DIR # YCSB must be executed in its own directory

  # record redis memory stat
  $REDIS_CLI info memory &> ${OUTFILE}_redis_info_memory

  echo "Waiting for redis workload to complete. (Redis server PID is ${EXE_PID}). \
      numastat is logged into ${OUTFILE}_numastat, PID is ${LOG_PID}" 

  # run ycsb run phase
  /usr/bin/numactl --membind=0 --cpunodebind=0 \
      ./bin/ycsb run redis -s -P workloads/workload_${WORKLOAD} -p "redis.host=127.0.0.1" -p "redis.port=6379" \
      -threads 16 &> ${OUTFILE}_ycsb_run

  # shutdown redis server
  $REDIS_CLI shutdown

  echo "Redis workload complete."
  # kill numastat process
  kill $LOG_PID
  popd
}


##############
# Script start
##############
trap clean_up SIGHUP SIGINT SIGTERM

[[ $EUID -ne 0 ]] && echo "This script must be run using sudo or as root." && exit 1

mkdir -p $RESULT_DIR

# All allocations on node 0
for workload in "${WORKLOAD_LIST[@]}"
do
  clean_cache
  run_redis "${RESULT_DIR}/${workload}_allnode0" $workload 0
  clean_cache
  run_redis "${RESULT_DIR}/${workload}_allnode1" $workload 1
done
