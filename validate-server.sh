#!/bin/bash

set -e  # Exit on any unhandled error

# List of required dependencies
DEPENDENCIES=("php" "composer" "npm" "node" "curl" "git" "jq")

# Paths and config file
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$ROOT_DIR/deploy-config.json"

# Required configuration keys
REQUIRED_CONFIG_KEYS=("deployment_prefix" "repository_url" "deploy_key" "env_file" "storage_symlink" "prod_symlink" "log_dir" "max_logs" "delete_failed_deploy")

# Detect package manager
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt-get"
    INSTALL_CMD="apt-get install -y"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
    INSTALL_CMD="yum install -y"
else
    echo "❌ Unsupported package manager. Please install dependencies manually."
    exit 1
fi

echo "📌 Using package manager: $PKG_MANAGER"

# Function to check dependencies
check_dependency() {
    local package=$1
    if ! command -v "$package" &>/dev/null; then
        echo "⚠️  $package is missing."
        while true; do
            read -p "Would you like to install $package? (y/n): " choice
            case "$choice" in
                y|Y ) sudo $INSTALL_CMD "$package"; break;;
                n|N ) echo "Skipping $package. You may need to install it manually."; break;;
                * ) echo "Please enter y or n.";;
            esac
        done
    else
        echo "✅ $package is installed."
    fi
}

# Check and prompt for each dependency
for dep in "${DEPENDENCIES[@]}"; do
    check_dependency "$dep"
done

# Validate Configuration File
echo "🔍 Checking configuration file: $CONFIG_FILE"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Configuration file not found!"
    exit 1
fi
echo "✅ Configuration file found."

# Function to validate all required configuration values
validate_config() {
    local key=$1
    local value=$(jq -r ".$key" "$CONFIG_FILE" 2>/dev/null)

    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "❌ Missing or empty value for '$key' in configuration file."
        exit 1
    fi
    echo "$value"  # Returns value for assignment
}

# Ensure all required configuration keys exist
for key in "${REQUIRED_CONFIG_KEYS[@]}"; do
    value=$(validate_config "$key")
    echo "✅ $key is set in configuration."
done

# Retrieve required values
DEPLOY_KEY=$(validate_config "deploy_key")
REPO_URL=$(validate_config "repository_url")

# Validate Deploy Key
echo "🔑 Checking deploy key: $DEPLOY_KEY"
if [[ ! -f "$DEPLOY_KEY" ]]; then
    echo "❌ Deploy key not found: $DEPLOY_KEY"
    while true; do
        read -p "Would you like to generate a new deploy key? (y/n): " choice
        case "$choice" in
            y|Y ) 
                ssh-keygen -t rsa -b 4096 -f "$DEPLOY_KEY" -N ""
                echo "✅ New deploy key generated: $DEPLOY_KEY"
                echo "Add the public key to GitHub: $(cat ${DEPLOY_KEY}.pub)"
                break;;
            n|N ) echo "Skipping deploy key generation. Ensure it exists."; exit 1;;
            * ) echo "Please enter y or n.";;
        esac
    done
else
    echo "✅ Deploy key exists."
fi

# Test GitHub Repository Access
echo "🔗 Testing GitHub repository access: $REPO_URL"
GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o StrictHostKeyChecking=no" git ls-remote "$REPO_URL" &>/dev/null
if [[ $? -ne 0 ]]; then
    echo "❌ Cannot access repository: $REPO_URL"
    exit 1
else
    echo "✅ GitHub repository is accessible."
fi

# Validate and Test Discord Webhooks (Optional)
echo "🔔 Checking Discord webhooks..."
if jq -e '.webhooks // empty' "$CONFIG_FILE" &>/dev/null; then
    # Extract all webhook keys (on_start, on_error, on_success, etc.)
    WEBHOOK_KEYS=$(jq -r '.webhooks | keys[]' "$CONFIG_FILE")

    for key in $WEBHOOK_KEYS; do
        # Get all URLs for the current webhook key
        WEBHOOK_URLS=$(jq -r ".webhooks[\"$key\"][]" "$CONFIG_FILE")

        for webhook in $WEBHOOK_URLS; do
            if [[ -n "$webhook" && "$webhook" != "null" ]]; then
                echo "📡 Sending test notification to Discord webhook ($key): $webhook"
                curl -H "Content-Type: application/json" -X POST -d "{\"content\": \"Test notification from validate-server.sh ($key)\"}" "$webhook" &>/dev/null
                if [[ $? -eq 0 ]]; then
                    echo "✅ Successfully sent test notification to: $webhook"
                else
                    echo "❌ Failed to send test notification to: $webhook"
                fi
            fi
        done
    done
else
    echo "⚠️  No Discord webhooks found in config. Skipping test."
fi

echo "🎉 Validation complete! Your server is ready for deployment."
exit 0
