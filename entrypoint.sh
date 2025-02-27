#!/bin/sh
set -e

if -f /akash-cfg/etcd.env; then
  set -a
  source /akash-cfg/config.env
  set +a
fi

# Generate Valkey config file
CONFIG_FILE="/usr/local/etc/valkey/valkey.conf"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Essential Valkey settings with defaults
: "${VALKEY_PORT:=6379}"
: "${VALKEY_BIND:=0.0.0.0}"
: "${VALKEY_MAXMEMORY:=0}"  # 0 means no limit
: "${VALKEY_MAXMEMORY_POLICY:=noeviction}"
: "${VALKEY_APPENDONLY:=no}"
: "${VALKEY_REQUIREPASS:=}"

cat > "$CONFIG_FILE" << EOF
# Network
bind ${VALKEY_BIND}
port ${VALKEY_PORT}
protected-mode yes

# Memory Management
maxmemory ${VALKEY_MAXMEMORY}
maxmemory-policy ${VALKEY_MAXMEMORY_POLICY}

# Persistence
dir /data
dbfilename db.rdb
appendonly ${VALKEY_APPENDONLY}

# Security
EOF

# Only add requirepass if it's set
if [ -n "$VALKEY_REQUIREPASS" ]; then
    echo "requirepass ${VALKEY_REQUIREPASS}" >> "$CONFIG_FILE"
fi

# Start backup process if enabled
if [ "$BACKUP_ENABLED" = "true" ]; then
    if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ] || [ -z "$S3_BUCKET" ]; then
        echo "Error: S3 configuration is incomplete. Please set all required environment variables."
        exit 1
    fi
    
    # Check if a backup exists in S3
    if [ -n "$(mc ls s3://${S3_BUCKET}/)" ]; then
        # Check for corruption in Redis data
        if redis-cli CHECK | grep -q "error"; then
            # Test restore from the latest backup
            if ! /usr/local/bin/backup.sh test-restore; then
                echo "Error: Restore test failed"
                exit 1
            fi
            # Restore data from the latest backup
            /usr/local/bin/backup.sh restore
        elif [ -z "$(ls -A ${REDIS_DATA_DIR})" ]; then
            # Test restore from the latest backup
            if ! /usr/local/bin/backup.sh test-restore; then
                echo "Error: Restore test failed"
                exit 1
            fi
            # Restore from the latest backup if data directory is empty
            /usr/local/bin/backup.sh restore
        fi
    fi
    
    # Schedule backups to S3 on a regular schedule
    if [ -z "$BACKUP_SCHEDULE" ]; then
        echo "Error: BACKUP_SCHEDULE environment variable is not set"
        exit 1
    fi
    echo "${BACKUP_SCHEDULE} /usr/local/bin/backup.sh backup" > /etc/crontab
    echo "0 0 1 * * /usr/local/bin/backup.sh test-restore" >> /etc/crontab
    supercronic /etc/crontab &
fi

# Start metrics components if METRICS_PASSWORD is set
if [ -n "$METRICS_PASSWORD" ]; then
    # Start metrics-exporter
    akash-metrics-exporter &
    # Start redis_exporter with authentication
    redis_exporter --redis.addr="redis://127.0.0.1:${VALKEY_PORT}" \
                  --redis.password="$VALKEY_REQUIREPASS" \
                  --web.listen-address=":9121" &

    # Start Akash metrics registrar
    akash-metrics-registrar \
        --target-host="localhost" \
        --target-port=9121 \
        --target-path="/metrics" \
        --metrics-port=9090 \
        --exporter-type="redis" \
        --metrics-password="${METRICS_PASSWORD}" &
fi

# Delegate to the original entrypoint script with our generated config
exec /usr/local/bin/docker-entrypoint.sh valkey-server "$CONFIG_FILE"
