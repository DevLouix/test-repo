#!/bin/bash
set -e

# -----------------------------
# HELPER FUNCTIONS
# -----------------------------
wait_for_container_ready() {
    local container_name="$1"
    local check_command="$2"
    local service_display_name="$3"
    local max_retries=30
    local counter=0

    echo "--- [WAITING] Waiting for $service_display_name to be ready... ---"
    while [ $counter -lt $max_retries ]; do
        if docker exec "$container_name" sh -c "$check_command" > /dev/null 2>&1; then
            echo "--- [SUCCESS] $service_display_name is up and ready! ---"
            return 0
        fi
        echo "Waiting for $service_display_name... ($((counter+1))/$max_retries)"
        sleep 2
        ((counter++))
    done
    echo "--- [ERROR] Timeout waiting for $service_display_name. ---"
    docker logs "$container_name" --tail 20
    exit 1
}

wait_for_local_port() {
    local port="$1"
    local service_name="$2"
    local max_retries=30
    local counter=0

    echo "--- [WAITING] Waiting for $service_name to listen on port $port... ---"
    while [ $counter -lt $max_retries ]; do
        if timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            echo "--- [SUCCESS] $service_name is listening on port $port! ---"
            return 0
        fi
        echo "Waiting for port $port... ($((counter+1))/$max_retries)"
        sleep 2
        ((counter++))
    done
    echo "--- [ERROR] Timeout waiting for $service_name on port $port. ---"
    exit 1
}

# -----------------------------
# MAIN SCRIPT
# -----------------------------
echo "--- [PROVISIONING] Starting self-contained environment setup ---"

# 1. SAFE CODESPACE NAME DETECTION
# This ensures we have the name so 'gh' doesn't ask us interactively
if [ -z "$CODESPACE_NAME" ]; then
    echo "--- [INFO] CODESPACE_NAME env var not found. Attempting to fetch... ---"
    CODESPACE_NAME=$(gh codespace view --json name -q .name 2>/dev/null)
fi

if [ -z "$CODESPACE_NAME" ]; then
    echo "--- [ERROR] Could not detect Codespace name. Make sure you are logged into gh cli. ---"
    exit 1
fi

echo "--- [INFO] Targeting Codespace: $CODESPACE_NAME ---"

API_CALLBACK_URL=https://studious-umbrella-xqjw9r5vrgw2x4q-3000.app.github.dev/api/workspaces/register
CALLBACK_SECRET=F3UTD-KW8P-9X2JQ-7V6ZLQ-1M5NBS-4Y3ZGA
DOCKER_IMAGE_URL=devlouix/agenta-server:latest
AGENT_NETWORK="agenta-net"

# 2. CREATE NETWORK
docker network create $AGENT_NETWORK || echo "Network exists."

# 3. START REDIS
REDIS_CONTAINER_NAME="agenta-redis"
echo "--- [PROVISIONING] Starting Redis... ---"
if [ ! "$(docker ps -q -f name=$REDIS_CONTAINER_NAME)" ]; then
    docker run -d --name $REDIS_CONTAINER_NAME --network $AGENT_NETWORK -v redis-data:/data redis:7-alpine
else
    echo "Redis is already running."
fi

# --> SEQ 1: WAIT FOR REDIS
wait_for_container_ready "$REDIS_CONTAINER_NAME" "redis-cli ping | grep PONG" "Redis"

# 4. PULL & RUN APP
echo "--- [PROVISIONING] Pulling image... ---"
docker pull $DOCKER_IMAGE_URL

SERVER_PORT=4000
APP_CONTAINER_NAME="agenta-server"
REDIS_URL="redis://$REDIS_CONTAINER_NAME:6379"
MONGO_URL="mongodb+srv://xilk:BONES123@dl-cluster.6evt6dh.mongodb.net/?retryWrites=true&w=majority&appName=DL-Cluster&dbName=/agenta"
SESSION_SECRET="lmxnC9sQW8vY2h1c3RvbS1tYWNoaW5lLXNlc3Npb24tc2VjcmV0LQ=="
CLIENT_ORIGIN="https://studious-umbrella-xqjw9r5vrgw2x4q-3000.app.github.dev"

echo "--- [PROVISIONING] Starting App Container... ---"
docker rm -f $APP_CONTAINER_NAME || true

docker run -d   -p $SERVER_PORT:$SERVER_PORT   --network $AGENT_NETWORK   -e REDIS_URL="$REDIS_URL"   -e REDIS_HOST="$REDIS_CONTAINER_NAME"   -e REDIS_PORT="6379"   -e MONGO_URL="$MONGO_URL"   -e MONGODB_URI="$MONGO_URL"   -e SESSION_SECRET="$SESSION_SECRET"   -e CLIENT_ORIGIN="$CLIENT_ORIGIN"   --name $APP_CONTAINER_NAME   $DOCKER_IMAGE_URL

# --> SEQ 2: WAIT FOR APP PORT
wait_for_local_port $SERVER_PORT "Agenta Server"

# -----------------------------
# 5. SET PORT VISIBILITY (Forces Public)
# -----------------------------
echo "--- [PROVISIONING] Setting port $SERVER_PORT visibility to public on $CODESPACE_NAME ---"

# We use 'visibility' which implies publish. We pass -c explicitly to avoid interactive prompt.
gh codespace ports visibility $SERVER_PORT:public -c "$CODESPACE_NAME"

# 6. WAIT FOR PUBLIC URL GENERATION
echo "--- [PROVISIONING] Fetching public URL... ---"
PUBLIC_URL=""
MAX_RETRIES=30
COUNTER=0

while [ -z "$PUBLIC_URL" ] || [ "$PUBLIC_URL" == "null" ]; do
    if [ $COUNTER -ge $MAX_RETRIES ]; then
        echo "ERROR: Timeout fetching URL."
        exit 1
    fi
    
    # Explicitly pass -c here too
    PUBLIC_URL=$(gh codespace ports -c "$CODESPACE_NAME" --json sourcePort,browseUrl -q "map(select(.sourcePort == $SERVER_PORT)) | .[0].browseUrl" || echo "")
    
    if [ -z "$PUBLIC_URL" ] || [ "$PUBLIC_URL" == "null" ]; then
        sleep 2
        ((COUNTER++))
    fi
done

echo "--- [PROVISIONING] Public URL: $PUBLIC_URL ---"

# -----------------------------
# 7. PATCH CALLBACK
# -----------------------------
# Only run callback if variables are set (prevents manual run crash if env vars missing)
if [ -n "$API_CALLBACK_URL" ] && [ -n "$CALLBACK_SECRET" ]; then
    echo "--- [PROVISIONING] Sending Callback... ---"
    curl --fail -X PATCH "$API_CALLBACK_URL"       -H "Content-Type: application/json"       -H "Authorization: Bearer $CALLBACK_SECRET"       -d '{ "codespaceName": "'"$CODESPACE_NAME"'", "publicUrl": "'"$PUBLIC_URL"'" }'
else
    echo "--- [INFO] Callback URL or Secret missing. Skipping callback (Manual run detected?). ---"
fi

echo "--- [PROVISIONING] Done! ---"