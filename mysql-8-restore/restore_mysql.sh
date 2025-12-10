#!/bin/bash
# Restore MySQL database from SQL or SQL.GZ backup
# Usage:
# ./restore_mysql.sh --name=SVBO --db=winvest --user=winvest --password=123456 --port=3306 --backup_dir=/SVBO

#├── SVBO
#│   ├── *.sql.gz
#└── restore.sh

# --- Parse all --key=value arguments ---
declare -A ARGS
for arg in "$@"; do
  if [[ $arg == --*=* ]]; then
    key="${arg%%=*}"
    val="${arg#*=}"
    key="${key#--}"
    ARGS["$key"]="$val"
  fi
done

# --- Function: get_arg <name> <default> ---
get_arg() {
  [[ -n "${ARGS[$1]}" ]] && echo "${ARGS[$1]}" || echo "$2"
}

# Config
DB_NAME=$(get_arg "db" "mydb")
DB_USER=$(get_arg "user" "root")
DB_PASSWORD=$(get_arg "password" "123456")
DB_PORT=$(get_arg "port" "3306")

DB_DATA_DIR=$(get_arg "data_dir" "/var/lib/mysql")
BACKUP_DIR=$(get_arg "backup_dir" "")
DB_SETUP_TIMEOUT_SECONDS=$(get_arg "timeout" "600")  # default 10 minutes

CONTAINER_NAME=$(get_arg "name" $DB_NAME)
VOLUME_NAME=$CONTAINER_NAME-vol

MYSQL_IMAGE=mysql:8.0

# --- Logging ---
LOG_DEBUG=1; LOG_INFO=2; LOG_WARN=3; LOG_ERROR=4
logger() {
  local message=$1
  local log_level=${2:-$LOG_INFO}  # Use LOG_INFO as the default log level
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case $log_level in 1) level="DEBUG";; 2) level="INFO";; 3) level="WARN";; 4) level="ERROR";; *) level="UNKNOWN";; esac
  echo "[$timestamp] [$level] - $message"
}

logger "Environment: { DB_NAME: $DB_NAME, DB_PASSWORD: $DB_PASSWORD, DB_USER: $DB_USER, DB_PORT: $DB_PORT, DB_DATA_DIR: $DB_DATA_DIR, DB_SETUP_TIMEOUT_SECONDS: $DB_SETUP_TIMEOUT_SECONDS }"

# --- Remove old container ---
if docker ps -aq --filter name="$CONTAINER_NAME" | grep -q .; then
  logger "Stopping container $(docker stop $CONTAINER_NAME)"
  logger "Removing container $(docker rm $CONTAINER_NAME)"
fi

# --- Remove + recreate volume ---
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  logger "Removing volume $(docker volume rm $VOLUME_NAME)"
fi
logger "Creating volume $(docker volume create $VOLUME_NAME)"

# --- Start MySQL container ---
container_id=$(docker run -d \
  --name $CONTAINER_NAME \
  -e MYSQL_ROOT_PASSWORD=$DB_PASSWORD \
  -e MYSQL_DATABASE=$DB_NAME \
  -e MYSQL_USER=$DB_USER \
  -e MYSQL_PASSWORD=$DB_PASSWORD \
  -p $DB_PORT:3306 \
  -v $VOLUME_NAME:$DB_DATA_DIR \
  -v $BACKUP_DIR:/backup \
  -v ./config/mysql/override.cnf:/etc/mysql/conf.d/override.cnf:ro \
  $MYSQL_IMAGE --lower_case_table_names=1
)

logger "Created new MySQL container: $container_id"

# --- Wait for MySQL to be ready ---
logger "Waiting for MySQL to start..."

start_time=$(date +%s)
while true; do
  if docker exec $CONTAINER_NAME mysqladmin -u"$DB_USER" -p"$DB_PASSWORD" ping --silent 2>/dev/null; then
    logger "MySQL is ready!"
    sleep 10
    break
  fi

  elapsed=$(( $(date +%s) - start_time ))
  if [[ $elapsed -ge $DB_SETUP_TIMEOUT_SECONDS ]]; then
    logger "Timeout: MySQL did not start within $DB_SETUP_TIMEOUT_SECONDS seconds" $LOG_ERROR
    exit 1
  fi

  sleep 5
done

# --- Locate backup file ---
BACKUP_FILE=$(ls -1 "$BACKUP_DIR"/*.sql* 2>/dev/null | head -n 1)
if [[ -z "$BACKUP_FILE" ]]; then
  logger "No SQL backup found inside $BACKUP_DIR" $LOG_ERROR
  exit 0
fi

logger "Found backup file: $BACKUP_FILE"

# --- Restore database ---
logger "Restoring MySQL database (this may take a while)..."

if [[ "$BACKUP_FILE" == *.gz ]]; then
  docker exec -i $CONTAINER_NAME bash -c \
    'gunzip -c "/backup/'"$(basename "$BACKUP_FILE")"'" | mysql --protocol=TCP -h127.0.0.1 -P3306 -u"'"$DB_USER"'" -p"'"$DB_PASSWORD"'" "'"$DB_NAME"'" 2>/dev/null'
else
  docker exec -i $CONTAINER_NAME bash -c \
    "mysql --protocol=TCP -h127.0.0.1 -P3306 -u$DB_USER -p$DB_PASSWORD $DB_NAME < /backup/$(basename $BACKUP_FILE)"
fi

logger "Restore completed!"

exit 0
