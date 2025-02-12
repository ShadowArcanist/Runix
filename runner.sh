#!/bin/bash
# ------------------------------------------------------------------------------
# This script builds a Docker image, pushes it to a local Docker registry,
# sets up an SSH tunnel to a remote VPS, triggers a deployment via Coolify,
# polls for the deployment status, cleans up resources, and finally notifies
# via Discord of the deployment outcome.
# ------------------------------------------------------------------------------

set -e                              # Exit immediately if any command returns a non-zero status.
set -o pipefail                     # In pipelines, the exit status of the last command to exit with a non-zero status will be used.

# ==============================================================================
# SECTION 1: CONFIGURATION VARIABLES (All variables centralized here)
# ==============================================================================

# -------------------------------
# Coolify Deployment Configuration
# -------------------------------
# These variables define how to interact with the Coolify API for deployments.
# - COOLIFY_FQDN: Fully Qualified Domain Name of your Coolify instance.
# - COOLIFY_TRIGGER_UUID: A unique identifier for triggering deployments. Find this in your Coolify webhook settings.
# - COOLIFY_TRIGGER_API_URL: The API endpoint used to trigger a deployment. The URL includes the trigger UUID and a force parameter.
# - COOLIFY_LIST_API_URL: The API endpoint to list deployments (used for polling the deployment status).
# - COOLIFY_API_TOKEN: The API token required for authentication with Coolify.
COOLIFY_FQDN="coolify.shadow.com"
COOLIFY_TRIGGER_UUID="ssg4w80o8g8994ws48sk40c8"
COOLIFY_TRIGGER_API_URL="https://${COOLIFY_FQDN}/api/v1/deploy?uuid=${COOLIFY_TRIGGER_UUID}&force=true"
COOLIFY_LIST_API_URL="https://${COOLIFY_FQDN}/api/v1/deployments"
COOLIFY_TARGET_APP_UUID="$COOLIFY_TRIGGER_UUID"  # Here, we reuse the trigger UUID as the target app identifier.
COOLIFY_API_TOKEN="69|9Iw1vHEIA4sY54pB7bCeI8vv3AMvcIhAAMpoZx2289a6e8157"

# -------------------------------
# Discord Notification Configuration
# -------------------------------
# Discord notifications allow you to get alerts regarding the deployment.
# - DISCORD_WEBHOOK_SUCCESS: Webhook URL for success notifications.
# - DISCORD_WEBHOOK_FAILURE: Webhook URL for failure notifications.
# - DISCORD_ALERT_PING: A string to mention a specific role or user for immediate attention.
DISCORD_WEBHOOK_SUCCESS="https://discord.com/api/webhooks/1036290328801579100/upk6lUa587MILEWnbHPEw92AHdDnUTA0FEnsnRiROHbc9-2U8n1XP1TrZdFnhYaA0BaA?thread_id=1336290591461470347"
DISCORD_WEBHOOK_FAILURE="https://discord.com/api/webhooks/1036290328801579100/upk6lUa587MILEWnbHPEw92AHdDnUTA0FEnsnRiROHbc9-2U8n1XP1TrZdFnhYaA0BaA?thread_id=1336290591461470347"
DISCORD_ALERT_PING="<@1327879920394829196>"  # This could be used to notify a team or individual immediately on Discord.

# -------------------------------
# VPS and SSH Configuration
# -------------------------------
# These settings are used for establishing an SSH tunnel to a Virtual Private Server (VPS).
# - VPS_IP: The IP address of your VPS.
# - VPS_USERNAME: The SSH username (often "root" or another administrative account).
# - VPS_PORT: The port on the VPS for SSH connections (default is 22, but this variable allows customization).
# - SSH_KEY_FILE: The path to your SSH private key file used for authentication.
VPS_IP="203.0.113.0"
VPS_USERNAME="fire"
VPS_PORT="69"
SSH_KEY_FILE="/Users/water/.ssh/ocean-dev"

# -------------------------------
# Docker Image Configuration
# -------------------------------
# These variables relate to the Docker image that will be built, tagged, and pushed.
# - IMAGE_NAME: The name of the Docker image (can be used as a repository name).
# - DOCKER_TAG: The tag for the Docker image (commonly "latest" for development builds).
IMAGE_NAME="dev"
DOCKER_TAG="latest"

# -------------------------------
# Deployment Polling Configuration
# -------------------------------
# Configure how the script polls the Coolify API to check deployment status.
# - DEPLOY_POLL_TIMEOUT: Maximum time (in seconds) to wait for the deployment to complete.
# - DEPLOY_POLL_INTERVAL: Interval (in seconds) between each poll to the Coolify API.
DEPLOY_POLL_TIMEOUT=60    # Maximum waiting time (in seconds) for the deployment process.
DEPLOY_POLL_INTERVAL=2    # Time interval (in seconds) between successive polls.

# -------------------------------
# Logging and Runner Configuration
# -------------------------------
# These variables define where log files are stored and identify this deployment runner.
# - LOG_DIR: The directory path where logs will be saved.
# - RUNNER_TARGET_NAME: A human-readable name for this deployment runner (useful in logs and notifications).
LOG_DIR="/Users/water/runners/dev"
RUNNER_TARGET_NAME="Development"

# ==============================================================================
# SECTION 2: GLOBAL VARIABLES AND LOG SETUP
# ==============================================================================

# Record the start time of the script to measure total runtime later.
START_TIME=$(date +%s)
# Create a unique log file based on the current time and date.
LOG_FILE="$LOG_DIR/$(date +"%I-%M%p-%b%d").txt"
# Ensure that the directory for log files exists.
mkdir -p "$LOG_DIR"

# Global variable to hold the Process ID (PID) of the SSH tunnel. This allows for later termination.
SSH_PID=""

# ==============================================================================
# SECTION 3: FUNCTION DEFINITIONS
# ==============================================================================

# ------------------------------------------------------------------------------
# Function: log
# Purpose : Logs a message with a timestamp to both the console and a log file.
# Input   : A string message to log.
# ------------------------------------------------------------------------------
log() {
  local message="$1"
  # Print the timestamped message to the console and append it to the log file.
  echo "$(date +"%Y-%m-%d %H:%M:%S") - $message" | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Function: send_discord_notification
# Purpose : Sends a rich embed notification to a Discord channel using a webhook.
# Inputs  : 
#   $1 - Discord webhook URL.
#   $2 - Title for the embed.
#   $3 - Description or content of the embed.
#   $4 - Color code (number) for the embed sidebar.
# ------------------------------------------------------------------------------
send_discord_notification() {
  local webhook_url="$1"
  local title="$2"
  local description="$3"
  local color="$4"

  # Build a JSON payload using jq to format the embed message correctly.
  local json_payload
  json_payload=$(jq -n \
    --arg title "$title" \
    --arg description "$description" \
    --argjson color "$color" \
    '{
      "embeds": [
        {
          "title": $title,
          "description": $description,
          "color": $color
        }
      ]
    }'
  )

  # Send the JSON payload via a POST request to the Discord webhook.
  curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$webhook_url"
}

# ------------------------------------------------------------------------------
# Function: send_plain_discord_failure
# Purpose : Sends a simple plain text message to Discord via a webhook.
# Inputs  :
#   $1 - Discord webhook URL.
#   $2 - Message content.
# ------------------------------------------------------------------------------
send_plain_discord_failure() {
  local webhook_url="$1"
  local message="$2"
  # Use curl to POST the message as JSON data.
  curl -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"$message\"}" \
    "$webhook_url"
}

# ------------------------------------------------------------------------------
# Function: cleanup
# Purpose : Cleans up resources on exit, such as terminating the SSH tunnel and removing the Docker registry container.
# Notes   : This function is triggered automatically on script exit, SIGINT, or SIGTERM.
# ------------------------------------------------------------------------------
cleanup() {
  # Check if the SSH tunnel is still running using its stored PID.
  if [ -n "$SSH_PID" ] && ps -p "$SSH_PID" > /dev/null 2>&1; then
    # Attempt to kill the SSH tunnel process and log the result.
    kill "$SSH_PID" && log "[ RunnerManager ] [ Success ] SSH tunnel (PID: $SSH_PID) terminated." || log "[ RunnerManager ] [ Warning ] Failed to terminate SSH tunnel (PID: $SSH_PID)."
  fi
  # Check if the Docker registry container is present (even if stopped).
  if docker ps -a --filter "name=registry" | grep -q "registry"; then
    # Forcefully remove the Docker registry container to free resources.
    docker rm -f registry > /dev/null 2>&1 && log "[ RunnerManager ] [ Success ] Docker registry terminated." || log "[ RunnerManager ] [ Error ] Failed to remove Docker registry container."
  fi
}
# Register the cleanup function to run on script exit or when receiving termination signals.
trap cleanup EXIT SIGINT SIGTERM

# ==============================================================================
# SECTION 4: MAIN SCRIPT EXECUTION
# ==============================================================================

# Log the initialization of the runner.
log "[ RunnerManager ] [ Info ] Initialized $RUNNER_TARGET_NAME Runner."

# -------------------------------
# Step 1: Build Docker Image
# -------------------------------
# This step builds a Docker image using the Dockerfile in the current directory.
log "[ RunnerManager ] [ Info ] Initiated Docker Image Build Process."
DOCKER_BUILD_START_TIME=$(date +%s)  # Record the start time for building the image.
# Build the Docker image and tag it with IMAGE_NAME:DOCKER_TAG.
if ! docker build -t "$IMAGE_NAME:$DOCKER_TAG" . > /dev/null 2>&1; then
  # If the Docker build fails, notify via Discord and exit.
  send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Failed to build Docker Image. $DISCORD_ALERT_PING"
  exit 1
fi

# Determine the size of the built Docker image for logging.
IMAGE_SIZE_BYTES=$(docker image inspect "$IMAGE_NAME:$DOCKER_TAG" --format='{{.Size}}')
# Convert the image size to MB or GB for readability.
if [ "$IMAGE_SIZE_BYTES" -lt 1073741824 ]; then
  IMAGE_SIZE=$(awk "BEGIN {printf \"%.2f MB\", $IMAGE_SIZE_BYTES/1024/1024}")
else
  IMAGE_SIZE=$(awk "BEGIN {printf \"%.2f GB\", $IMAGE_SIZE_BYTES/1024/1024/1024}")
fi
log "[ RunnerManager ] [ Success ] Docker Image Built with Size: $IMAGE_SIZE."

# -------------------------------
# Step 2: Start Docker Registry (if not running)
# -------------------------------
# The local Docker registry is used to temporarily store and serve the Docker image.
log "[ RunnerManager ] [ Info ] Fetching Docker Registry Status."
# Check if a Docker container named "registry" is currently running.
if ! docker ps --filter "name=registry" --filter "status=running" | grep -q "registry"; then
  # If not running, start a new Docker registry container.
  if ! docker run -d -p 5000:5000 --name registry --tmpfs /var/lib/registry registry:2 > /dev/null 2>&1; then
    # On failure, send an alert via Discord and exit.
    send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Failed to start Docker Registry. $DISCORD_ALERT_PING"
    exit 1
  fi
  log "[ RunnerManager ] [ Success ] Docker registry was offline. Started it now."
else
  log "[ RunnerManager ] [ Success ] Docker registry is already running."
fi

# -------------------------------
# Step 3: Push Docker Image to Registry
# -------------------------------
# Prepare the Docker image for the remote VPS by pushing it to the local registry.
log "[ RunnerManager ] [ Info ] Initiated Docker image upload to registry."
# Tag the locally built image so that it points to the local registry (localhost:5000).
docker tag "$IMAGE_NAME:$DOCKER_TAG" "localhost:5000/$IMAGE_NAME:$DOCKER_TAG" > /dev/null 2>&1
# Push the tagged image to the local Docker registry.
if ! docker push "localhost:5000/$IMAGE_NAME:$DOCKER_TAG" > /dev/null 2>&1; then
  # On failure to push the image, notify via Discord and exit.
  send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Failed to push Image to Registry. $DISCORD_ALERT_PING"
  exit 1
fi
log "[ RunnerManager ] [ Success ] Docker image uploaded to registry."

# -------------------------------
# Step 4: Create SSH Tunnel to VPS
# -------------------------------
# The SSH tunnel is created to allow the remote VPS to access the local Docker registry.
log "[ RunnerManager ] [ Info ] Initiated SSH tunnel to VPS."
# Establish the SSH tunnel:
#   - "-i" specifies the SSH key file for authentication.
#   - "-p" uses the VPS_PORT variable to connect to the correct port.
#   - "-o ExitOnForwardFailure=yes" ensures the command exits if the tunnel cannot be established.
#   - "-o ServerAliveInterval=30" sends keepalive messages to maintain the connection.
#   - "-N" tells SSH not to execute a remote command (tunnel only).
#   - "-R 5000:localhost:5000" forwards remote port 5000 to local port 5000.
ssh -i "$SSH_KEY_FILE" -p "$VPS_PORT" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -N -R 5000:localhost:5000 "$VPS_USERNAME@$VPS_IP" &
# Capture the Process ID (PID) of the SSH tunnel.
SSH_PID=$!
# Allow a brief pause to give the SSH tunnel time to establish.
sleep 2
# Verify that the SSH tunnel process is running.
if ! ps -p "$SSH_PID" > /dev/null 2>&1; then
  # If the tunnel failed to start, send a Discord alert and exit.
  send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Failed to setup SSH Tunnel to Remote Server. $DISCORD_ALERT_PING"
  exit 1
fi
log "[ RunnerManager ] [ Success ] SSH tunnel established (PID: $SSH_PID)."

# -------------------------------
# Step 5: Trigger Coolify Deployment
# -------------------------------
# This step instructs Coolify to start the deployment process using its API.
log "[ RunnerManager ] [ Info ] Triggered Coolify Deployment."
# Perform a POST request to the Coolify trigger endpoint using curl.
if ! curl -s -X POST "$COOLIFY_TRIGGER_API_URL" -H "Authorization: Bearer $COOLIFY_API_TOKEN" > /dev/null 2>&1; then
  # If the request fails, send a failure notification via Discord and exit.
  send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Failed to trigger Coolify deployment. $DISCORD_ALERT_PING"
  exit 1
fi

# -------------------------------
# Step 6: Poll Coolify API for Deployment Status
# -------------------------------
# After triggering the deployment, the script polls the Coolify API until the deployment completes.
log "[ RunnerManager ] [ Info ] Asking Coolify for deployment status"
poll_start_time=$(date +%s)  # Record the start time for polling.
deployment_complete=false    # Initialize a flag to track deployment completion.
while true; do
  current_time=$(date +%s)
  elapsed=$(( current_time - poll_start_time ))
  # If the polling duration exceeds the timeout, log an error and notify via Discord.
  if [ $elapsed -ge $DEPLOY_POLL_TIMEOUT ]; then
    log "[ RunnerManager ] [ Error ] Deployment polling timed out after ${DEPLOY_POLL_TIMEOUT}s."
    send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Deployment polling timed out after ${DEPLOY_POLL_TIMEOUT}s. $DISCORD_ALERT_PING"
    exit 1
  fi

  # Make a GET request to retrieve the list of current deployments.
  response=$(curl -s -X GET "$COOLIFY_LIST_API_URL" -H "Authorization: Bearer $COOLIFY_API_TOKEN")
  # Check if the target deployment's UUID is still present in the response.
  if echo "$response" | grep -q "$COOLIFY_TARGET_APP_UUID"; then
    log "[ RunnerManager ] [ Info ] Deployment is still in progress, checking again in $DEPLOY_POLL_INTERVAL seconds."
  else
    log "[ RunnerManager ] [ Success ] Deployment completed."
    deployment_complete=true  # Set the flag to true and break out of the loop.
    break
  fi

  sleep "$DEPLOY_POLL_INTERVAL"  # Wait before polling again.
done

# -------------------------------
# Step 7: Terminate SSH Tunnel
# -------------------------------
# Once the deployment is complete, it is safe to close the SSH tunnel.
log "[ RunnerManager ] [ Info ] Terminating SSH tunnel."
# Check if the SSH tunnel process is still active.
if [ -n "$SSH_PID" ] && ps -p "$SSH_PID" > /dev/null 2>&1; then
  # Terminate the SSH tunnel and log the result.
  kill "$SSH_PID" && log "[ RunnerManager ] [ Success ] SSH tunnel (PID: $SSH_PID) terminated." || log "[ RunnerManager ] [ Warning ] Failed to terminate SSH tunnel (PID: $SSH_PID)."
  SSH_PID=""  # Clear the SSH_PID variable.
else
  log "[ RunnerManager ] [ Info ] SSH tunnel already terminated."
fi

# -------------------------------
# Step 8: Cleanup Docker Images
# -------------------------------
# To free up disk space and avoid clutter, remove the Docker images created during the build.
log "[ RunnerManager ] [ Info ] Initiated Docker images cleanup."
# Remove the locally built Docker image.
if ! docker rmi "$IMAGE_NAME:$DOCKER_TAG" > /dev/null 2>&1; then
  log "[ RunnerManager ] [ Error ] Failed to remove local Docker image: ($IMAGE_NAME:$DOCKER_TAG)."
  send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Failed to remove local Docker Image ($IMAGE_NAME:$DOCKER_TAG). $DISCORD_ALERT_PING"
fi
# Remove the Docker image that was pushed to the local registry.
if ! docker rmi "localhost:5000/$IMAGE_NAME:$DOCKER_TAG" > /dev/null 2>&1; then
  log "[ RunnerManager ] [ Error ] Failed to remove pushed Docker image: (localhost:5000/$IMAGE_NAME:$DOCKER_TAG)."
  send_plain_discord_failure "$DISCORD_WEBHOOK_FAILURE" "[ <t:$(date +%s):T> (<t:$(date +%s):R>) ] [ $RUNNER_TARGET_NAME ] Failed to remove Docker Image on Registry (localhost:5000/$IMAGE_NAME:$DOCKER_TAG). $DISCORD_ALERT_PING"
fi
log "[ RunnerManager ] [ Success ] Docker images cleanup completed."

# -------------------------------
# Step 9: Calculate Total Runtime
# -------------------------------
# Compute the total time taken by the script to execute.
END_TIME=$(date +%s)
TOTAL_TIME=$(( END_TIME - START_TIME ))
# Format the runtime into minutes and seconds.
MINUTES=$(( TOTAL_TIME / 60 ))
SECONDS=$(( TOTAL_TIME % 60 ))
if [ "$MINUTES" -gt 0 ]; then
  FORMATTED_TIME="${MINUTES}m ${SECONDS}s"
else
  FORMATTED_TIME="${SECONDS}s"
fi

# -------------------------------
# Step 10: Final Discord Notification
# -------------------------------
# Compose a summary message with statistics about the Docker image and overall runtime.
DISCORD_MESSAGE="
** **
**Docker Stats**
> - **Image Name:** $IMAGE_NAME
> - **Image Tag:** $DOCKER_TAG
> - **Image Size:** $IMAGE_SIZE
** **
**Runner Stats**
> - **Started on:** <t:$START_TIME:T>
> - **Ended on:** <t:$END_TIME:T>
> - **Total Runtime:** $FORMATTED_TIME"
# Send a final success notification to Discord with all the gathered stats.
send_discord_notification "$DISCORD_WEBHOOK_SUCCESS" "[ $RUNNER_TARGET_NAME ] Deployment Success!" "$DISCORD_MESSAGE" 0

# Log the final result to the log file.
log "[ RunnerManager ] [ Result ] $RUNNER_TARGET_NAME Runner execution completed, total runtime: $FORMATTED_TIME."

# Exit successfully.
exit 0
