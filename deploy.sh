#!/bin/bash

set -e  # Exit on any unhandled error

# Load configuration file
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"  # Ensure ROOT_DIR is absolute
CONFIG_FILE="$ROOT_DIR/deploy-config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found."
    exit 1
fi

# Function to validate configuration values
validate_config() {
    local key=$1
    local value=$(jq -r ".$key" "$CONFIG_FILE" 2>/dev/null)

    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "Error: Missing or empty value for '$key' in configuration file."
        exit 1
    fi

    echo "$value"
}

# Function to send a Discord message (optional)
send_discord_message() {
    local message="$1"
    local webhook_key="$2"

    local webhooks=$(jq -r ".webhooks.$webhook_key[]" "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$webhooks" || "$webhooks" == "null" ]]; then
        echo "⚠️  No Discord webhook found for $webhook_key. Skipping notification."
        return 0
    fi

    for webhook in $webhooks; do
        curl -H "Content-Type: application/json" -X POST -d "{\"content\": \"$message\"}" "$webhook" &>/dev/null
    done
}

# **Rollback function**
rollback() {
    local rollback_target="No previous deployment available."

    if [[ -n "$PREVIOUS_TARGET" ]]; then
        log "Rolling back to previous deployment: $PREVIOUS_TARGET"
        ln -sfn "$PREVIOUS_TARGET" "$ROOT_DIR/$PROD_SYMLINK"
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Rolled back to $PREVIOUS_TARGET due to deployment failure." >> "$ROOT_DIR/.prod-app-log"
        rollback_target="Rolled back to ${PREVIOUS_TARGET#$ROOT_DIR/}"
    fi

    # Delete failed deployment if enabled in config
    if [[ "$DELETE_FAILED_DEPLOY" == "true" ]]; then
        log "Deleting failed deployment directory: $DEPLOY_DIR"
        rm -rf "$DEPLOY_DIR"
    fi

    local log_filename=$(basename "$LOG_FILE")  # Extract only the filename
    send_discord_message "**Deployment failed!**\nCheck log: \`$LOG_DIR/$log_filename\`\n$rollback_target" "on_error"
    log "Deployment failed. Check logs for details."
    exit 1
}

# Extract and validate configuration values
DEPLOYMENT_PREFIX=$(validate_config "deployment_prefix")
REPO_URL=$(validate_config "repository_url")
DEPLOY_KEY=$(validate_config "deploy_key")
ENV_FILE=$(validate_config "env_file")
STORAGE_SYMLINK=$(validate_config "storage_symlink")
PROD_SYMLINK=$(validate_config "prod_symlink")
LOG_DIR=$(validate_config "log_dir")
MAX_LOGS=$(validate_config "max_logs")
DELETE_FAILED_DEPLOY=$(validate_config "delete_failed_deploy")

# Ensure deploy key exists
if [[ ! -f "$DEPLOY_KEY" ]]; then
    rollback
fi

# Generate Deployment Directory (Ensure absolute path)
TIMESTAMP=$(date +'%Y%m%d-%H%M')
DEPLOY_DIR="$ROOT_DIR/$DEPLOYMENT_PREFIX-$TIMESTAMP"
COUNT=1

# Ensure unique directory name
while [[ -d "$DEPLOY_DIR" ]]; do
    DEPLOY_DIR="${ROOT_DIR}/${DEPLOYMENT_PREFIX}-${TIMESTAMP}-$COUNT"
    ((COUNT++))
done

# Create deployment directory
mkdir -p "$DEPLOY_DIR"

# Prepare log directory (Use absolute path)
mkdir -p "$ROOT_DIR/$LOG_DIR"
LOG_FILE="$ROOT_DIR/$LOG_DIR/$(basename "$DEPLOY_DIR").txt"

# Function to log messages
log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
    fi
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

# Backup the previous production target before updating
PREVIOUS_TARGET=""
PROD_LOG_FILE="$ROOT_DIR/.prod-app-log"
PREV_TARGET_FILE="$ROOT_DIR/.previous-prod-target"

# Ensure log files exist
touch "$PROD_LOG_FILE"
touch "$PREV_TARGET_FILE"

if [[ -L "$ROOT_DIR/$PROD_SYMLINK" ]]; then
    PREVIOUS_TARGET=$(readlink "$ROOT_DIR/$PROD_SYMLINK")
    
    log "Previous deployment target: $PREVIOUS_TARGET"
    
    # Append previous target to .prod-app-log with timestamp
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $PREVIOUS_TARGET" >> "$PROD_LOG_FILE"
    
    # Overwrite .previous-prod-target with the last deployment path
    echo "$PREVIOUS_TARGET" > "$PREV_TARGET_FILE"
fi

# Send start notification
send_discord_message "**Deployment started!**\nDeploying to: \`${DEPLOY_DIR#$ROOT_DIR/}\`" "on_start"

log "Starting deployment in directory: $DEPLOY_DIR"

# Clone repository using deploy key
log "Cloning repository using deploy key: $REPO_URL"
GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o StrictHostKeyChecking=no" git clone "$REPO_URL" "$DEPLOY_DIR" 2>&1 | tee -a "$LOG_FILE"
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    rollback
fi

# Change to deployment directory
cd "$DEPLOY_DIR"

# Run Laravel installation commands
log "Running composer install"
if ! command -v composer >/dev/null; then rollback; fi
if ! composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader | tee -a "$LOG_FILE"; then rollback; fi

log "Running npm install"
if ! command -v npm >/dev/null; then rollback; fi
if ! npm install | tee -a "$LOG_FILE"; then rollback; fi

log "Running php artisan down"
if ! command -v php >/dev/null; then rollback; fi
if ! php artisan down | tee -a "$LOG_FILE"; then rollback; fi

# Set rollback on any failure
trap rollback ERR

# Run optimization and migration commands (Rollback on failure)
log "Running php artisan clear-compiled"
php artisan clear-compiled | tee -a "$LOG_FILE" || rollback

log "Running php artisan optimize"
php artisan optimize | tee -a "$LOG_FILE" || rollback

log "Running npm run prod"
npm run prod | tee -a "$LOG_FILE" || rollback

log "Running php artisan migrate --force"
php artisan migrate --force | tee -a "$LOG_FILE" || rollback

# Bring application back online (Rollback if this fails)
log "Running php artisan up"
php artisan up | tee -a "$LOG_FILE" || rollback

# Remove rollback trap on success
trap - ERR

# Send success notification
send_discord_message "**Deployment completed successfully!**\nNow running: \`${DEPLOY_DIR#$ROOT_DIR/}\`" "on_success"

log "Deployment completed successfully!"
exit 0
