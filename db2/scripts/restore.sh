#!/bin/bash
# Restore DB2 db

# ./restore.sh --db=<DBNAME> --port=<PORT> --data_dir=<DATA_DIR> --backup_dir=<BACKUP_DIR> --timeout=<TIMEOUT> --instance=<INSTANCE> --password=<PWD>
# ./restore.sh --db=CSBFO --port=50000 --data_dir=/data --backup_dir=/home/db/CSBFO/backup

# Note: <DATA_DIR> is depended on DBNAME, CSB is /data, but GJS is /DB,...

#├── CSBFO
#│   ├── backup
#│   │   └── CSBFO.0.db2inst1.DBPART000.20251202001614.00
#│   └── script
#│       └── script1.sql
#├── prepare.sh
#└── restore.sh

# --- Parse all --key=value arguments ---
declare -A ARGS
for arg in "$@"; do
  if [[ $arg == --*=* ]]; then
    key="${arg%%=*}"        # before '='
    val="${arg#*=}"         # after '='
    key="${key#--}"         # remove leading --
    ARGS["$key"]="$val"
  fi
done

# --- Function: get_arg <name> <default> ---
get_arg() {
  local name="$1"
  local default="$2"

  if [[ -n "${ARGS[$name]}" ]]; then
    echo "${ARGS[$name]}"
  else
    echo "$default"
  fi
}

# DB config
DB_PORT=$(get_arg "port" "50000")
DB_INSTANCE=$(get_arg "instance" "winvest")
DB_PASSWORD=$(get_arg "password" "123456")
DB_NAME=$(get_arg "db" "CSBFO")
# Original container and volume
ORIG_CONTAINER_NAME=$DB_NAME
ORIG_VOLUME_NAME=$DB_NAME-vol
ORIG_DB_VOLUME_NAME=$DB_NAME-db
# Data dir
DB_DATA_DIR=$(get_arg "data_dir" "")
# Backup dir
BACKUP_DIR=$(get_arg "backup_dir" "")
# Set the maximum waiting time in seconds
DB_SETUP_TIMEOUT_SECONDS=$(get_arg "timeout" "1200")  # Adjust as needed
# DB docker image
DB_IMAGE=ibmcom/db2:11.5.8.0

# Define log levels
LOG_DEBUG=1
LOG_INFO=2
LOG_WARN=3
LOG_ERROR=4

# Function to log messages
logger() {
  local message=$1
  local log_level=${2:-$LOG_INFO}  # Use LOG_INFO as the default log level
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case $log_level in 1) level="DEBUG";; 2) level="INFO";; 3) level="WARN";; 4) level="ERROR";; *) level="UNKNOWN";; esac
  echo "[$timestamp] [$level] - $message"
}

# Check if the original container exists
if docker ps -aq --filter name="$ORIG_CONTAINER_NAME" | grep -q .; then
  # Stop original container
  logger "Stop original container: $(docker stop $ORIG_CONTAINER_NAME)"
  logger "Remove original container: $(docker rm $ORIG_CONTAINER_NAME)"
fi

# Check if the original volume exists
if docker volume inspect "$ORIG_VOLUME_NAME" >/dev/null 2>&1; then
  logger "Remove volume $(docker volume rm $ORIG_VOLUME_NAME)"
fi
logger "Create new volume $(docker volume create $ORIG_VOLUME_NAME)"

# Check if the original volume exists
if docker volume inspect "$ORIG_DB_VOLUME_NAME" >/dev/null 2>&1; then
  logger "Remove volume $(docker volume rm $ORIG_DB_VOLUME_NAME)"
fi
logger "Create new volume $(docker volume create $ORIG_DB_VOLUME_NAME)"
# Create and run container
container_id=$(docker run -d --name $ORIG_CONTAINER_NAME \
  --privileged=true \
  -p $DB_PORT:50000 \
  -e LICENSE=accept \
  -e DB2INST1_PASSWORD=$DB_PASSWORD \
  -e WINVEST_PASSWORD=$DB_PASSWORD \
  -e DB2INSTANCE=$DB_INSTANCE \
  -v $ORIG_VOLUME_NAME:/database \
  -v $ORIG_DB_VOLUME_NAME:$DB_DATA_DIR \
  -v $BACKUP_DIR:/backup \
  $DB_IMAGE)
logger "Created new container with name = $ORIG_CONTAINER_NAME ; id = $container_id"

# Function to check if the setup has completed
check_setup_completed() {
  if docker logs "$ORIG_CONTAINER_NAME" 2>&1 | grep -q "Setup has completed"; then
    return 0  # The message is found
  else
    return 1  # The message is not found
  fi
}

# Poll for the setup completion message with a timeout
start_time=$(date +%s)
while ! check_setup_completed; do
  current_time=$(date +%s)
  elapsed_time=$((current_time - start_time))
  
  if [ "$elapsed_time" -ge "$DB_SETUP_TIMEOUT_SECONDS" ]; then
    logger "Timeout reached. Setup did not complete within $DB_SETUP_TIMEOUT_SECONDS seconds." $LOG_ERROR
    exit 1
  fi

  logger "Waiting for DB2 instance setup to complete..."
  sleep 5  # Adjust the polling interval as needed
done

logger "DB2 instance is now initialized and ready for connections."

# Create data_dir firstly
docker exec -i "$ORIG_CONTAINER_NAME" /bin/bash -c "chown $DB_INSTANCE:db2iadm1 $DB_DATA_DIR"

# Restore
logger "Restoring db, it may take a while, please don't kill this terminal ..."
# Run the SQL file using db2cli within the container
docker exec -i $ORIG_CONTAINER_NAME /bin/bash <<EOF
  su - $DB_INSTANCE > /dev/null
  db2 restore db $DB_NAME from /backup without rolling forward
EOF

# DONE
elapsed_time=$((current_time - start_time))
logger "Completed! ($elapsed_time (ms))"
exit 0
