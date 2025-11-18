#!/bin/bash
set -e # Exit immediately if a command fails

echo "--- [PROVISIONING] Starting self-contained environment setup ---"

# --- These variables are injected by your Next.js API ---
#if [ -z "$API_CALLBACK_URL" ] || [ -z "$CALLBACK_SECRET" ] || [ -z "$DOCKER_IMAGE_URL" ]; then
#  echo "--- [PROVISIONING] ERROR: Required environment variables are not set. ---"
#  exit 1
#fi

API_CALLBACK_URL=https://studious-umbrella-xqjw9r5vrgw2x4q-3001.app.github.dev/api/workspaces/register
CALLBACK_SECRET=F3UTD-KW8P-9X2JQ-7V6ZLQ-1M5NBS-4Y3ZGA
DOCKER_IMAGE_URL=devlouix/agenta-server:latest
CODESPACE_NAME=$(gh codespace view --json name | jq -r '.name')

# 1. CREATE A DEDICATED DOCKER NETWORK
# This allows containers to find each other by name.
AGENT_NETWORK="agenta-net"
docker network create $AGENT_NETWORK || echo "Network $AGENT_NETWORK already exists."

# 2. START THE REDIS CONTAINER
# It will run in the background on the network we just created.
REDIS_CONTAINER_NAME="agenta-redis"
echo "--- [PROVISIONING] Starting Redis container ($REDIS_CONTAINER_NAME)... ---"
docker run -d   --name $REDIS_CONTAINER_NAME   --network $AGENT_NETWORK   -v redis-data:/data   redis:7-alpine

# The Redis URL your app will use. It connects to the container by its name.
export REDIS_URL="redis://$REDIS_CONTAINER_NAME:6379"
echo "--- [PROVISIONING] Redis is running. Internal URL: $REDIS_URL ---"

# 3. PULL YOUR APPLICATION IMAGE FROM DOCKER HUB
echo "--- [PROVISIONING] Pulling server image: $DOCKER_IMAGE_URL ---"
docker pull $DOCKER_IMAGE_URL

# 4. RUN YOUR APPLICATION CONTAINER
# It connects to the same network and is given the Redis URL.
SERVER_PORT=4000
APP_CONTAINER_NAME="agenta-server"
echo "--- [PROVISIONING] Running application container ($APP_CONTAINER_NAME)... ---"
docker run -d   -p $SERVER_PORT:$SERVER_PORT   --network $AGENT_NETWORK   -e REDIS_URL="$REDIS_URL"   --name $APP_CONTAINER_NAME   $DOCKER_IMAGE_URL

# --- (The rest of the script for port forwarding and phoning home is unchanged) ---
echo "--- [PROVISIONING] Waiting 15 seconds for port to stabilize... ---"
sleep 15


echo "--- [PROVISIONING] Fetching public URL... ---"

# This command should now succeed because the port is already set to public by devcontainer.json
PUBLIC_URL=$(gh codespace ports --json -c $CODESPACE_NAME | jq -r ".[] | select(.sourcePort==$SERVER_PORT) | .browseUrl")

if [ -z "$PUBLIC_URL" ]; then
  echo "--- [PROVISIONING] ERROR: Failed to get public URL. Ensure port 4000 is configured correctly in devcontainer.json. ---"
  exit 1
fi

echo "--- [PROVISIONING] Public URL found: $PUBLIC_URL ---"
echo "--- [PROVISIONING] Calling home to register URL... ---"

curl --fail -X PATCH "$API_CALLBACK_URL"   -H "Content-Type: application/json"   -H "Authorization: Bearer $CALLBACK_SECRET"   -d '{
  "codespaceName": "'"$CODESPACE_NAME"'",
  "publicUrl": "'"$PUBLIC_URL"'"
}'

echo "--- [PROVISIONING] Setup complete! Environment is live. ---"