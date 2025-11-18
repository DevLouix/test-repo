#!/bin/bash
set -e # Exit immediately if a command fails

echo "--- [PROVISIONING] Starting self-contained environment setup ---"

# --- These variables are injected by your Next.js API ---
# (Ensure these variables are actually available in your environment)
API_CALLBACK_URL=https://studious-umbrella-xqjw9r5vrgw2x4q-3001.app.github.dev/api/workspaces/register
CALLBACK_SECRET=F3UTD-KW8P-9X2JQ-7V6ZLQ-1M5NBS-4Y3ZGA
DOCKER_IMAGE_URL=devlouix/agenta-server:latest

# Fetch the Codespace name safely
CODESPACE_NAME=$(gh codespace view --json name -q .name)

# 1. CREATE A DEDICATED DOCKER NETWORK
AGENT_NETWORK="agenta-net"
docker network create $AGENT_NETWORK || echo "Network $AGENT_NETWORK already exists."

# 2. START THE REDIS CONTAINER
REDIS_CONTAINER_NAME="agenta-redis"
echo "--- [PROVISIONING] Starting Redis container ($REDIS_CONTAINER_NAME)... ---"
# Check if already running to avoid conflicts on rebuilds
if [ ! "$(docker ps -q -f name=$REDIS_CONTAINER_NAME)" ]; then
    docker run -d       --name $REDIS_CONTAINER_NAME       --network $AGENT_NETWORK       -v redis-data:/data       redis:7-alpine
else
    echo "Redis container already running."
fi

export REDIS_URL="redis://$REDIS_CONTAINER_NAME:6379"
echo "--- [PROVISIONING] Redis is running. Internal URL: $REDIS_URL ---"

# 3. PULL YOUR APPLICATION IMAGE
echo "--- [PROVISIONING] Pulling server image: $DOCKER_IMAGE_URL ---"
docker pull $DOCKER_IMAGE_URL

# 4. RUN YOUR APPLICATION CONTAINER
SERVER_PORT=4000
APP_CONTAINER_NAME="agenta-server"
echo "--- [PROVISIONING] Running application container ($APP_CONTAINER_NAME)... ---"

if [ ! "$(docker ps -q -f name=$APP_CONTAINER_NAME)" ]; then
    docker run -d       -p $SERVER_PORT:$SERVER_PORT       --network $AGENT_NETWORK       -e REDIS_URL="$REDIS_URL"       --name $APP_CONTAINER_NAME       $DOCKER_IMAGE_URL
else
    echo "Application container already running."
fi

# 5. FETCH PUBLIC URL WITH RETRY LOGIC (THE FIX)
echo "--- [PROVISIONING] Waiting for port $SERVER_PORT to be registered... ---"

PUBLIC_URL=""
MAX_RETRIES=30 # Wait up to 60 seconds (30 * 2s)
COUNTER=0

while [ -z "$PUBLIC_URL" ] || [ "$PUBLIC_URL" == "null" ]; do
    if [ $COUNTER -ge $MAX_RETRIES ]; then
        echo "--- [PROVISIONING] ERROR: Timed out waiting for public URL. ---"
        exit 1
    fi

    # Use 'gh codespace ports' which is more robust than the raw API for this task
    PUBLIC_URL=$(gh codespace ports --json localPort,externalUrl -q "map(select(.localPort == $SERVER_PORT)) | .[0].externalUrl")

    if [ -z "$PUBLIC_URL" ] || [ "$PUBLIC_URL" == "null" ]; then
        echo "Port URL not ready yet. Retrying in 2s... ($COUNTER/$MAX_RETRIES)"
        sleep 2
        ((COUNTER++))
    fi
done

echo "--- [PROVISIONING] Public URL found: $PUBLIC_URL ---"

echo "--- [PROVISIONING] Calling home to register URL... ---"
curl --fail -X PATCH "$API_CALLBACK_URL"   -H "Content-Type: application/json"   -H "Authorization: Bearer $CALLBACK_SECRET"   -d '{
    "codespaceName": "'"$CODESPACE_NAME"'",
    "publicUrl": "'"$PUBLIC_URL"'"
  }'

echo "--- [PROVISIONING] Setup complete! Environment is live. ---"