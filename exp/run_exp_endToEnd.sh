#!/bin/bash

#TODO: which memory should the YCSB client use? How much memory does it use? The load phase probably does not matter,
#      but run phase client does
# import common functions
if [ "$BIGMEMBENCH_COMMON_PATH" = "" ] ; then
  echo "ERROR: bigmembench_common script not found. BIGMEMBENCH_COMMON_PATH is $BIGMEMBENCH_COMMON_PATH"
  echo "Have you set BIGMEMBENCH_COMMON_PATH correctly? Are you using sudo -E instead of just sudo?"
  exit 1
fi
source ${BIGMEMBENCH_COMMON_PATH}/run_exp_common.sh

REDIS_DIR="/ssd1/songxin8/thesis/keyValStore/redis/"
REDIS_CLI="${REDIS_DIR}/src/redis-cli"
YCSB_DIR="/ssd1/songxin8/thesis/keyValStore/YCSB/"
WORKLOAD_DIR="${YCSB_DIR}/workloads/" 

RESULT_DIR="/ssd1/songxin8/thesis/keyValStore/YCSB/exp/exp_endToEnd/"
NUM_THREADS=16
MEMCONFIG="${NUM_THREADS}threads"

declare -a WORKLOAD_LIST=("USR" "VAR")

clean_up () {
    echo "Cleaning up. Kernel PID is $EXE_PID, numastat PID is $NUMASTAT_PID, top PID is $TOP_PID"
    # Perform program exit housekeeping
    kill $NUMASTAT_PID
    kill $TOP_PID
    kill $EXE_PID
    exit
}

run_app () { 
  OUTFILE_NAME=$1
  WORKLOAD=$2
  CONFIG=$3

  OUTFILE_PATH="${RESULT_DIR}/${OUTFILE_NAME}"

  if [[ "$CONFIG" == "ALL_LOCAL" ]]; then
    # All local config: place both data and compute on node 1
    COMMAND_COMMON="/usr/bin/time -v /usr/bin/numactl --membind=1 --cpunodebind=1"
  elif [[ "$CONFIG" == "EDGES_ON_REMOTE" ]]; then
    # place edges array on node 1, rest on node 0
    COMMAND_COMMON="/usr/bin/time -v /usr/bin/numactl --membind=0 --cpunodebind=0"
  elif [[ "$CONFIG" == "TPP" ]]; then
    # only use node 0 CPUs and let TPP decide how memory is placed
    COMMAND_COMMON="/usr/bin/time -v /usr/bin/numactl --cpunodebind=0"
  elif [[ "$CONFIG" == "AUTONUMA" ]]; then
    COMMAND_COMMON="/usr/bin/time -v /usr/bin/numactl --cpunodebind=0"
  else
    echo "Error! Undefined configuration $CONFIG"
    exit 1
  fi

  echo "Start" > ${OUTFILE_PATH}-redisOut
  echo "NUMA hardware config is: " >> ${OUTFILE_PATH}-redisOut
  NUMACTL_OUT=$(numactl -H)
  echo "$NUMACTL_OUT" >> ${OUTFILE_PATH}-redisOut

  # change to dir with rdb dumps
  pushd $REDIS_DIR

  # start redis server.
  # there should be a corresponding confg file named redis_${WORKLOAD}.conf
  # e.g. for zippydb, we use redis_zippydb.conf to indicate the RDB file to load.
  ${COMMAND_COMMON} -- $REDIS_DIR/src/redis-server $REDIS_DIR/redis_${WORKLOAD}.conf &>> ${OUTFILE_PATH}-redisOut &

  # PID of time command
  TIME_PID=$! 
  # get PID of actual kernel, which is a child of time. 
  # This PID is needed for the numastat command
  EXE_PID=$(pgrep -P $TIME_PID)

  echo "Waiting 5min for redis to finish loading keys from RDB..."
  # wait for RDB loading to finish. a 40GB redis-server takes ~3min to load from RDB.
  sleep 300

  echo "redis server PID is ${EXE_PID}"
  echo "start" > ${OUTFILE_PATH}-numastat 
  while true; do numastat -p $EXE_PID >> ${OUTFILE_PATH}-numastat; sleep 5; done &
  NUMASTAT_PID=$!

  sleep 10 # wait for redis server to go up

  popd
  # run ycsb load phase
  pushd $YCSB_DIR # YCSB must be executed in its own directory

  # record redis memory stat
  $REDIS_CLI info memory &> ${OUTFILE_PATH}-redisInfoMemory

  top -b -d 10 -1 -p $EXE_PID > ${OUTFILE_PATH}-topLog &
  TOP_PID=$!

  echo "Waiting for redis workload to complete. (Redis server PID is ${EXE_PID}). \
      numastat is logged into ${OUTFILE_PATH}_numastat, PID is ${NUMASTAT_PID}. Top PID is $TOP_PID" 

  # run ycsb run phase
  # which memory should this use? How much memory?
  #/usr/bin/numactl --membind=0 --cpunodebind=0 \
  ./bin/ycsb run redis -s -P workloads/workload_${WORKLOAD} -p "redis.host=127.0.0.1" -p "redis.port=6379" \
      -threads ${NUM_THREADS} &> ${OUTFILE_PATH}-ycsbRun

  # shutdown redis server
  $REDIS_CLI shutdown

  echo "Redis workload complete."
  kill $NUMASTAT_PID
  kill $TOP_PID
  popd
}


##############
# Script start
##############
trap clean_up SIGHUP SIGINT SIGTERM

mkdir -p $RESULT_DIR

echo "NUMA hardware config is: "
NUMACTL_OUT=$(numactl -H)
echo "$NUMACTL_OUT"

# TPP
enable_tpp
for workload in "${WORKLOAD_LIST[@]}"
do
  clean_cache
  LOGFILE_NAME=$(gen_file_name "redis" "${workload}" "${MEMCONFIG}_tpp")
  run_app $LOGFILE_NAME $workload "TPP"
done

# AutoNUMA. not specifying where to allocate. Let AutoNUMA decide 
enable_autonuma
for workload in "${WORKLOAD_LIST[@]}"
do
  clean_cache
  LOGFILE_NAME=$(gen_file_name "redis" "${workload}" "${MEMCONFIG}_autonuma")
  run_app $LOGFILE_NAME $workload "AUTONUMA"
done

# allocate all data on local memory
disable_numa
for workload in "${WORKLOAD_LIST[@]}"
do
  clean_cache
  LOGFILE_NAME=$(gen_file_name "redis" "${workload}" "${MEMCONFIG}_allLocal")
  run_app $LOGFILE_NAME $workload "ALL_LOCAL"
done

