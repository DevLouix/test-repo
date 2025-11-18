#!/bin/bash
set -e

echo "--- [PROVISIONING] Starting self-contained environment setup ---"

API_CALLBACK_URL=https://studious-umbrella-xqjw9r5vrgw2x4q-3001.app.github.dev/api/workspaces/register
CALLBACK_SECRET=F3UTD-KW8P-9X2JQ-7V6ZLQ-1M5NBS-4Y3ZGA
DOCKER_IMAGE_URL=devlouix/agenta-server:latest

CODESPACE_NAME=$(gh codespace view --json name -q .name)
AGENT_NETWORK="agenta-net"

# 1. CREATE NETWORK
docker network create $AGENT_NETWORK || echo "Network exists."

# 2. START REDIS
REDIS_CONTAINER_NAME="agenta-redis"
echo "--- [PROVISIONING] Starting Redis... ---"
if [ ! "$(docker ps -q -f name=$REDIS_CONTAINER_NAME)" ]; then
    docker run -d --name $REDIS_CONTAINER_NAME --network $AGENT_NETWORK -v redis-data:/data redis:7-alpine
fi


# 4. PULL & RUN APP
echo "--- [PROVISIONING] Pulling image... ---"
docker pull $DOCKER_IMAGE_URL

SERVER_PORT=4000
APP_CONTAINER_NAME="agenta-server"

# Define connection strings using container names, NOT localhost
REDIS_URL="redis://$REDIS_CONTAINER_NAME:6379"
MONGO_URL="mongodb+srv://xilk:BONES123@dl-cluster.6evt6dh.mongodb.net/?retryWrites=true&w=majority&appName=DL-Cluster&dbName=/agenta"
SESSION_SECRET="lmxnC9sQW8vY2h1c3RvbS1tYWNoaW5lLXNlc3Npb24tc2VjcmV0LQ=="
CLIENT_ORIGIN="https://studious-umbrella-xqjw9r5vrgw2x4q-3000.app.github.dev"

echo "--- [PROVISIONING] Starting App... ---"
# We remove the old one to ensure new env vars are applied
docker rm -f $APP_CONTAINER_NAME || true

docker run -d   -p $SERVER_PORT:$SERVER_PORT   --network $AGENT_NETWORK   -e REDIS_URL="$REDIS_URL"   -e REDIS_HOST="$REDIS_CONTAINER_NAME"   -e REDIS_PORT="6379"   -e MONGO_URL="$MONGO_URL"   -e MONGODB_URI="$MONGO_URL"   -e SESSION_SECRET="$SESSION_SECRET"   -e CLIENT_ORIGIN="$CLIENT_ORIGIN"   --name $APP_CONTAINER_NAME   $DOCKER_IMAGE_URL

# 5. WAIT FOR PORT
echo "--- [PROVISIONING] Waiting for port $SERVER_PORT... ---"
PUBLIC_URL=""
MAX_RETRIES=30
COUNTER=0

while [ -z "$PUBLIC_URL" ] || [ "$PUBLIC_URL" == "null" ]; do
    if [ $COUNTER -ge $MAX_RETRIES ]; then
        echo "ERROR: Timeout waiting for URL."
        exit 1
    fi
    # Force codespace target to ensure we get the right ports
    PUBLIC_URL=$(gh codespace ports -c "$CODESPACE_NAME" --json sourcePort,browseUrl -q "map(select(.sourcePort == $SERVER_PORT)) | .[0].browseUrl")
    
    if [ -z "$PUBLIC_URL" ] || [ "$PUBLIC_URL" == "null" ]; then
        sleep 2
        ((COUNTER++))
    fi
done

echo "--- [PROVISIONING] Public URL: $PUBLIC_URL ---"

curl --fail -X PATCH "$API_CALLBACK_URL"   -H "Content-Type: application/json"   -H "Authorization: Bearer $CALLBACK_SECRET"   -d '{ "codespaceName": "'"$CODESPACE_NAME"'", "publicUrl": "'"$PUBLIC_URL"'" }'

echo "--- [PROVISIONING] Done! ---"