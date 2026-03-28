#!/bin/bash
# ============================================================
# Gallery Compatible App — Deploy Script Template
# ============================================================
#
# Usage:
#   ./deploy.sh <tag>                      # Deploy with default snow connection
#   ./deploy.sh <tag> <snow-connection>    # Deploy with specific connection
#
# Examples:
#   ./deploy.sh v1                         # First deploy
#   ./deploy.sh v2                         # Update deploy
#   ./deploy.sh v1 my_prod_connection      # Deploy to a specific account
#
# Prerequisites:
#   - Docker Desktop running
#   - snow CLI installed and configured
#   - Image repository created in Snowflake
#   - Application package created with stage
#
# Setup (run once before first deploy):
#   snow sql -q "CREATE DATABASE IF NOT EXISTS <APP_DB>"
#   snow sql -q "CREATE SCHEMA IF NOT EXISTS <APP_DB>.<APP_SCHEMA>"
#   snow sql -q "CREATE IMAGE REPOSITORY IF NOT EXISTS <APP_DB>.<APP_SCHEMA>.<APP_REPO>"
#   snow sql -q "CREATE APPLICATION PACKAGE IF NOT EXISTS <APP_PKG>"
#   snow sql -q "CREATE SCHEMA IF NOT EXISTS <APP_PKG>.APP_SRC"
#   snow sql -q "CREATE STAGE IF NOT EXISTS <APP_PKG>.APP_SRC.STAGE DIRECTORY = (ENABLE = TRUE)"
#
# ============================================================

set -e

# ── Configuration (edit these for your app) ──

APP_NAME="<APP_NAME>"
APP_PKG="<APP_NAME>_PKG"
REGISTRY_PATH="<ACCOUNT>.registry.snowflakecomputing.com/<APP_DB>/<APP_SCHEMA>/<APP_REPO>/<CONTAINER_NAME>"
STAGE="@${APP_PKG}.APP_SRC.STAGE"

# Files to upload to stage (add or remove as needed)
DEPLOY_FILES=(
    "deploy/manifest.yml"
    "deploy/service_spec.yml"
    "deploy/setup.sql"
    "deploy/config.sql"
    "deploy/services.sql"
    "deploy/README.md"
)

# Streamlit files (uploaded to streamlit/ subdirectory on stage)
STREAMLIT_FILES=(
    "deploy/streamlit/setup_ui.py"
    "deploy/streamlit/environment.yml"
)

# ── Parse arguments ──

TAG="${1:?Usage: deploy.sh <tag> [snow-connection]}"
VERSION=$(echo "$TAG" | tr '[:lower:]' '[:upper:]')  # v1 -> V1
CONNECTION="${2:-}"

if [ -n "$CONNECTION" ]; then
    CONN_FLAG="-c ${CONNECTION}"
else
    CONN_FLAG=""
fi

echo "============================================"
echo "  Deploying ${APP_NAME} as ${VERSION}"
echo "  Registry: ${REGISTRY_PATH}:${TAG}"
echo "  Connection: ${CONNECTION:-default}"
echo "============================================"

# ── Step 1: Build Docker image ──

echo ""
echo "--- Step 1: Build Docker image ---"
docker build -t "${APP_NAME}:latest" -f docker/Dockerfile .

# ── Step 2: Tag and push to Snowflake registry ──

echo ""
echo "--- Step 2: Push image to registry ---"
docker tag "${APP_NAME}:latest" "${REGISTRY_PATH}:${TAG}"

REGISTRY_HOST=$(echo "$REGISTRY_PATH" | cut -d/ -f1)
snow spcs image-registry token ${CONN_FLAG} --format=JSON 2>/dev/null | \
    docker login "${REGISTRY_HOST}" --username 0sessiontoken --password-stdin

docker push "${REGISTRY_PATH}:${TAG}"

# ── Step 3: Update manifest and service_spec with new tag ──

echo ""
echo "--- Step 3: Update manifest/spec to :${TAG} ---"
sed -i "s/${APP_NAME##*/}:v[0-9]*/${APP_NAME##*/}:${TAG}/g" \
    deploy/manifest.yml deploy/service_spec.yml

# ── Step 4: Upload all files to stage ──

echo ""
echo "--- Step 4: Upload files to stage ---"

for f in "${DEPLOY_FILES[@]}"; do
    echo "  PUT ${f}"
    snow sql ${CONN_FLAG} -q "PUT 'file://${f}' ${STAGE}/ OVERWRITE=TRUE AUTO_COMPRESS=FALSE" 2>&1 | tail -1
done

for f in "${STREAMLIT_FILES[@]}"; do
    echo "  PUT ${f} -> streamlit/"
    snow sql ${CONN_FLAG} -q "PUT 'file://${f}' ${STAGE}/streamlit/ OVERWRITE=TRUE AUTO_COMPRESS=FALSE" 2>&1 | tail -1
done

# ── Step 5: Deregister old version + register new ──

echo ""
echo "--- Step 5: Register version ${VERSION} ---"

# Deregister (ignore error if version doesn't exist)
snow sql ${CONN_FLAG} -q \
    "ALTER APPLICATION PACKAGE ${APP_PKG} DEREGISTER VERSION ${VERSION}" 2>&1 | tail -1 || true

# Register
snow sql ${CONN_FLAG} -q \
    "ALTER APPLICATION PACKAGE ${APP_PKG} REGISTER VERSION ${VERSION} USING '${STAGE}'" 2>&1 | tail -1

# ── Step 6: Upgrade or create application ──
# UPGRADE preserves consumer settings (DB connections, EAI, compute pool).
# CREATE is used only on first deploy or when UPGRADE is not possible.

echo ""
echo "--- Step 6: Deploy application ---"

# Set release directive
snow sql ${CONN_FLAG} -q \
    "USE ROLE ACCOUNTADMIN; ALTER APPLICATION PACKAGE ${APP_PKG} SET DEFAULT RELEASE DIRECTIVE VERSION = ${VERSION} PATCH = 0" 2>&1 | tail -1

# Try UPGRADE first
UPGRADE_RESULT=$(snow sql ${CONN_FLAG} -q \
    "USE ROLE ACCOUNTADMIN; ALTER APPLICATION ${APP_NAME} UPGRADE" 2>&1)

if echo "$UPGRADE_RESULT" | grep -q "error\|Error\|does not exist"; then
    echo "  UPGRADE not available — creating fresh application"
    snow sql ${CONN_FLAG} -q \
        "USE ROLE ACCOUNTADMIN; CREATE WAREHOUSE IF NOT EXISTS SETUP_WH WAREHOUSE_SIZE='XSMALL' AUTO_SUSPEND=60 AUTO_RESUME=TRUE; USE WAREHOUSE SETUP_WH; CREATE APPLICATION ${APP_NAME} FROM APPLICATION PACKAGE ${APP_PKG} USING VERSION ${VERSION}" 2>&1 | tail -3
else
    echo "  UPGRADE succeeded — consumer settings preserved"
    echo "$UPGRADE_RESULT" | tail -1
fi

# ── Step 7: Verify ──

echo ""
echo "--- Step 7: Verify ---"
snow sql ${CONN_FLAG} -q \
    "SELECT CURRENT_ACCOUNT() AS account; SHOW APPLICATIONS LIKE '${APP_NAME}'" 2>&1 | head -10

echo ""
echo "=== Deploy complete: ${APP_NAME} ${VERSION} ==="
echo ""
echo "Next steps:"
echo "  1. Open the app in Snowsight and complete the Setup wizard"
echo "  2. Approve EAI in Configurations tab"
echo "  3. Start the service"
