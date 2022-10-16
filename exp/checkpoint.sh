#!/bin/bash


REDIS_DIR="/ssd1/songxin8/thesis/keyValStore/redis/"
REDIS_CLI="${REDIS_DIR}/src/redis-cli"
YCSB_DIR="/ssd1/songxin8/thesis/keyValStore/YCSB/"
WORKLOAD_DIR="${YCSB_DIR}/workloads/" 

RESULT_DIR="/ssd1/songxin8/thesis/keyValStore/YCSB/exp/checkpoint/"

#declare -a WORKLOAD_LIST=("workload_zippydb")
#declare -a WORKLOAD_LIST=("workload_zippydb_small")
declare -a WORKLOAD_LIST=("workload_up2x")

clean_up () {
    echo "Cleaning up. Kernel PID is $EXE_PID"
    # Perform program exit housekeeping
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

  # start redis server
  $REDIS_DIR/src/redis-server $REDIS_DIR/redis.conf &

  EXE_PID=$!

  sleep 10 # wait for redis server to go up

  # run ycsb load phase
  pushd $YCSB_DIR # YCSB must be executed in its own directory

  ./bin/ycsb load redis -s -P workloads/$WORKLOAD -p "redis.host=127.0.0.1" -p "redis.port=6379" -threads 64 &> ${OUTFILE}_ycsb_load

  # save checkpoint to dump.rdb
  echo "Saving checkpoint to disk. This may take a while depending on the size of the data set."
  $REDIS_CLI save
  # shutdown redis server
  echo "Checkpointing complete."
  $REDIS_CLI shutdown

  popd
  mv dump.rdb ${WORKLOAD}.rdb

  echo "Checkpoint stored at ${PWD}/${WORKLOAD}.rdb"
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
  run_redis "${RESULT_DIR}/${workload}" $workload
done
