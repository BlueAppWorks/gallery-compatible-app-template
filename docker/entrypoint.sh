#!/bin/bash
set -e

echo "=== Application Starting ==="
echo "Started at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ============================================================
# Load credentials from Snowflake Secret
# Secrets are mounted at /snowflake/session/secrets/<SECRET_NAME>/
# with 'username' and 'password' files auto-generated.
# ============================================================
SECRET_PATH="/snowflake/session/secrets/<SECRET_NAME>"

if [ -f "${SECRET_PATH}/username" ]; then
    export DB_USER=$(cat "${SECRET_PATH}/username")
    export DB_PASSWORD=$(cat "${SECRET_PATH}/password")
    echo "Credentials loaded from Snowflake Secret"
else
    echo "Using credentials from environment variables"
fi

# Connection settings (injected via service_spec.yml template variables)
export DB_HOST=${DB_HOST:?DB_HOST is required}
export DB_PORT=${DB_PORT:-5432}

echo "Target: ${DB_USER}@${DB_HOST}:${DB_PORT}"

# ============================================================
# Wait for DNS resolution (EAI activation can take a few seconds)
# ============================================================
echo ""
echo "Waiting for DNS resolution of ${DB_HOST}..."
MAX_RETRIES=30
RETRY_COUNT=0
while true; do
    if getent hosts "${DB_HOST}" > /dev/null 2>&1; then
        RESOLVED_IP=$(getent hosts "${DB_HOST}" | awk '{print $1}')
        echo "DNS resolved: ${DB_HOST} -> ${RESOLVED_IP}"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]; then
        echo "WARNING: DNS resolution failed after ${MAX_RETRIES} retries"
        echo "Proceeding anyway..."
        break
    fi
    echo "  DNS not ready, retrying in 5s (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep 5
done

# ============================================================
# Wait for TCP connectivity
# ============================================================
echo ""
echo "Testing TCP connectivity to ${DB_HOST}:${DB_PORT}..."
RETRY_COUNT=0
while true; do
    if timeout 5 bash -c "echo > /dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
        echo "TCP connection succeeded"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ ${RETRY_COUNT} -ge 10 ]; then
        echo "WARNING: TCP connectivity check timed out"
        echo "Proceeding anyway..."
        break
    fi
    echo "  TCP not ready, retrying in 5s (${RETRY_COUNT}/10)..."
    sleep 5
done

# ============================================================
# Start your application
# Replace this with your app's actual startup command.
# ============================================================
echo ""
echo "Starting application..."
exec python app.py
