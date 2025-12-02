#!/bin/bash

# Clone original DB (from ./restore.sh) to new instance, and stop original DB

# ./prepare.sh --db=<DBNAME> --port=<PORT> --data_dir=<DATA_DIR> --script_dir=<PRE_SCRIPT_DIR> --timeout=<TIMEOUT> --instance=<INSTANCE> --password=<PWD>
# ./prepare.sh --db=CSBFO --port=50000 --data_dir=/data --script_dir=/home/db/CSBFO/script

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
# Cloned container and volume
CONTAINER_NAME=$DB_NAME-clone
VOLUME_NAME=$DB_NAME-vol-clone
DB_VOLUME_NAME=$DB_NAME-db-clone
# Set the maximum waiting time in seconds
DB_SETUP_TIMEOUT_SECONDS=$(get_arg "timeout" "1200")  # Adjust as needed
# Data dir
DB_DATA_DIR=$(get_arg "data_dir" "")
# SCRIPT DIR
PRE_SCRIPT_DIR=$(get_arg "script_dir" "")

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
else
  logger "Container $ORIG_CONTAINER_NAME doesn't exist -> exit" $LOG_ERROR
  exit 1;
fi

# Check if the original volume exists
if docker volume inspect "$ORIG_VOLUME_NAME" >/dev/null 2>&1; then
  # Do nothing
  true
else
  logger "Volume $ORIG_VOLUME_NAME doesn't exist -> exit" $LOG_ERROR
  exit 1;
fi

# Check if the original volume exists
if docker volume inspect "$ORIG_DB_VOLUME_NAME" >/dev/null 2>&1; then
  # Do nothing
  true
else
  logger "Volume $ORIG_DB_VOLUME_NAME doesn't exist -> exit" $LOG_ERROR
  exit 1;
fi

# Check if the cloned container exists
if docker ps -aq --filter name="$CONTAINER_NAME" | grep -q .; then
  logger "Found existed container named $CONTAINER_NAME -> stop and remove"
  logger "Stop container $(docker stop $CONTAINER_NAME)"
  logger "Remove container $(docker rm $CONTAINER_NAME)"
fi

# Check if the cloned volume exists
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  logger "Found existed volume named $VOLUME_NAME -> remove and create the new one"
  logger "Remove volume $(docker volume rm $VOLUME_NAME)"
fi
logger "Create new volume $(docker volume create $VOLUME_NAME)"

# Check if the cloned volume exists
if docker volume inspect "$DB_VOLUME_NAME" >/dev/null 2>&1; then
  logger "Found existed volume named $DB_VOLUME_NAME -> remove and create the new one"
  logger "Remove volume $(docker volume rm $DB_VOLUME_NAME)"
fi
logger "Create new volume $(docker volume create $DB_VOLUME_NAME)"

# Clone volume
logger "Clone volume $ORIG_VOLUME_NAME -> $VOLUME_NAME"
docker run --rm -v $ORIG_VOLUME_NAME:/source -v $VOLUME_NAME:/target alpine cp -a /source/. /target/ > /dev/null
logger "Clone volume $ORIG_DB_VOLUME_NAME -> $DB_VOLUME_NAME"
docker run --rm -v $ORIG_DB_VOLUME_NAME:/source -v $DB_VOLUME_NAME:/target alpine cp -a /source/. /target/ > /dev/null
# Create clone container
container_id=$(docker run -d --name $CONTAINER_NAME \
  --privileged=true \
  -p $DB_PORT:50000 \
  -e LICENSE=accept \
  -e DB2INST1_PASSWORD=$DB_PASSWORD \
  -e WINVEST_PASSWORD=$DB_PASSWORD \
  -e DB2INSTANCE=$DB_INSTANCE \
  -v $VOLUME_NAME:/database \
  -v $DB_VOLUME_NAME:$DB_DATA_DIR \
  ibmcom/db2:11.5.8.0)
logger "Created new container with name = $ORIG_CONTAINER_NAME ; id = $container_id"

# Function to check if the setup has completed
check_setup_completed() {
  if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Setup has completed"; then
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
  sleep 10  # Adjust the polling interval as needed
done

logger "DB2 instance is now initialized and ready for connections."

# Run scripts
# Iterate over each .sql file in the specified directory
for sql_file in "$PRE_SCRIPT_DIR"/*.sql; do
  if [ -e "$sql_file" ]; then
    # Copy the .sql file into the DB2 container's /tmp/ directory
    docker cp "$sql_file" "$CONTAINER_NAME":/tmp/ > /dev/null
    
    # Get the filename without the path and extension
    filename=$(basename -- "$sql_file")
    file_log="${filename%.*}.log"

    # Change the permissions of the copied file to make it readable by all users
    docker exec -i "$CONTAINER_NAME" /bin/bash -c "chmod +rx /tmp/$filename"
    docker exec -i "$CONTAINER_NAME" /bin/bash -c "touch /tmp/$file_log"
    docker exec -i "$CONTAINER_NAME" /bin/bash -c "chown $DB_INSTANCE:db2iadm1 /tmp/$file_log"
    
    # Run the SQL file using db2cli within the container
    docker exec -i $CONTAINER_NAME /bin/bash <<EOF
  su - $DB_INSTANCE  > /dev/null
  db2 connect to $DB_NAME user $DB_INSTANCE using $DB_PASSWORD  > /dev/null
  db2 -tvf /tmp/$filename > /tmp/$file_log 
EOF

    # Remove the copied .sql file from the container
    docker exec -i "$CONTAINER_NAME" /bin/bash -c "rm /tmp/$filename"
    
    logger "Executed $filename"
  else
    logger "No .sql files found in $PRE_SCRIPT_DIR"
  fi
done

# DONE
elapsed_time=$((current_time - start_time))
logger "Completed! ($elapsed_time (ms))"
exit 0
