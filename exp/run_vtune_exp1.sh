#!/bin/bash

REDIS_DIR="/ssd1/songxin8/thesis/keyValStore/redis/"
REDIS_CLI="${REDIS_DIR}/src/redis-cli"
YCSB_DIR="/ssd1/songxin8/thesis/keyValStore/YCSB/"
WORKLOAD_DIR="${YCSB_DIR}/workloads/" 
WORKING_DIR=$REDIS_DIR

RESULT_DIR="/ssd1/songxin8/thesis/keyValStore/vtune/sweep_exp1/"

declare -a WORKLOAD_LIST=("USR" "VAR")

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

run_redis_hotspot () { 
  WORKLOAD=$1
  MEMNODE=$2

  # start redis server
  LD_PRELOAD=/usr/lib/x86_64-linux-gnu/debug/libstdc++.so.6.0.28 /opt/intel/oneapi/vtune/2022.3.0/bin64/vtune -collect hotspots -start-paused -data-limit=10000 -result-dir ${RESULT_DIR}/${WORKLOAD}_hotspot_node${MEMNODE} --app-working-dir=${WORKING_DIR} -- /usr/bin/numactl --membind=${MEMNODE} --cpunodebind=0 $REDIS_DIR/src/redis-server $REDIS_DIR/redis_${WORKLOAD}.conf &
  VTUNE_PID=$!

  echo "[INFO] Sleeping to wait for redis server to finish loading from RDB."
  sleep 400 

  pushd $YCSB_DIR # YCSB must be executed in its own directory

  # resume vtunes data collection
  /opt/intel/oneapi/vtune/2022.3.0/bin64/vtune -command resume -r ${RESULT_DIR}/${WORKLOAD}_hotspot_node${MEMNODE}

  # run ycsb run phase. The YCSB process should be on node 0
  /usr/bin/numactl --membind=0 --cpunodebind=0 \
      ./bin/ycsb run redis -s -P workloads/workload_$WORKLOAD -p "redis.host=127.0.0.1" -p "redis.port=6379" \
      -threads 16

  # shutdown redis server
  $REDIS_CLI shutdown
  wait $VTUNE_PID
  popd
}

run_redis_memacc () { 
  WORKLOAD=$1
  MEMNODE=$2

  # start redis server
  LD_PRELOAD=/usr/lib/x86_64-linux-gnu/debug/libstdc++.so.6.0.28 /opt/intel/oneapi/vtune/2022.3.0/bin64/vtune -collect memory-access -start-paused -knob sampling-interval=10 -knob analyze-mem-objects=true -knob analyze-openmp=true -data-limit=10000 -result-dir ${RESULT_DIR}/${WORKLOAD}_memacc_node${MEMNODE} --app-working-dir=${WORKING_DIR} -- /usr/bin/numactl --membind=${MEMNODE} --cpunodebind=0 $REDIS_DIR/src/redis-server $REDIS_DIR/redis_${WORKLOAD}.conf &
  VTUNE_PID=$!

  echo "[INFO] Sleeping to wait for redis server to finish loading from RDB."
  sleep 400 

  pushd $YCSB_DIR # YCSB must be executed in its own directory

  # resume vtunes data collection
  echo "[INFO] Resuming vtunes collection."
  /opt/intel/oneapi/vtune/2022.3.0/bin64/vtune -command resume -r ${RESULT_DIR}/${WORKLOAD}_memacc_node${MEMNODE}

  # run ycsb run phase. The YCSB process should be on node 0
  echo "[INFO] Running YCSB run phase."
  /usr/bin/numactl --membind=0 --cpunodebind=0 \
      ./bin/ycsb run redis -s -P workloads/workload_${WORKLOAD} -p "redis.host=127.0.0.1" -p "redis.port=6379" \
      -threads 16

  # shutdown redis server
  $REDIS_CLI shutdown
  wait $VTUNE_PID
  popd
}

run_redis_uarch () { 
  WORKLOAD=$1
  MEMNODE=$2

  # start redis server
  LD_PRELOAD=/usr/lib/x86_64-linux-gnu/debug/libstdc++.so.6.0.28 \
      /opt/intel/oneapi/vtune/2022.3.0/bin64/vtune \
      -collect uarch-exploration -start-paused -knob sampling-interval=10 -knob collect-memory-bandwidth=true \
      -data-limit=10000 -result-dir ${RESULT_DIR}/${WORKLOAD}_uarch_node${MEMNODE} \
      --app-working-dir=${WORKING_DIR} \
      -- /usr/bin/numactl --membind=${MEMNODE} --cpunodebind=0 \
      $REDIS_DIR/src/redis-server $REDIS_DIR/redis_${WORKLOAD}.conf &
  VTUNE_PID=$!

  echo "[INFO] Sleeping to wait for redis server to finish loading from RDB."
  sleep 400 

  pushd $YCSB_DIR # YCSB must be executed in its own directory

  # resume vtunes data collection
  /opt/intel/oneapi/vtune/2022.3.0/bin64/vtune -command resume -r ${RESULT_DIR}/${WORKLOAD}_uarch_node${MEMNODE}

  # run ycsb run phase. The YCSB process should be on node 0
  /usr/bin/numactl --membind=0 --cpunodebind=0 \
      ./bin/ycsb run redis -s -P workloads/workload_$WORKLOAD -p "redis.host=127.0.0.1" -p "redis.port=6379" \
      -threads 16

  # shutdown redis server
  $REDIS_CLI shutdown
  wait $VTUNE_PID
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
  #clean_cache
  #run_redis_hotspot $workload 0
  #clean_cache
  #run_redis_hotspot $workload 1
  #clean_cache
  #run_redis_memacc $workload 0
  #clean_cache
  #run_redis_memacc $workload 1
  clean_cache
  run_redis_uarch $workload 0
  #clean_cache
  #run_redis_uarch $workload 1
done
