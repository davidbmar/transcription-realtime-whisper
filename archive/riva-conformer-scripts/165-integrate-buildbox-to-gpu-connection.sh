#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 165: Integrate Build Box Bridge with GPU Connection
# ============================================================================
# Connects the deployed WebSocket bridge to the GPU RIVA server.
# This script auto-detects the model type on the GPU and configures
# the bridge to use the correct settings.
#
# Category: BUILD BOX SERVICES - Integration
# This script: ~10 seconds
#
# What this does:
# 1. Verify bridge deployment exists (script 155)
# 2. Auto-detect deployed model on GPU (Conformer-CTC or Parakeet RNNT)
# 3. Update RIVA_HOST and RIVA_MODEL in bridge .env file
# 4. Configure model-specific settings (punctuation, word offsets)
# 5. Fix file permissions (SSL certs, logs, .env)
# 6. Restart WebSocket bridge service
# 7. Validate connection to GPU RIVA server
#
# Prerequisites:
# - Script 155 completed (WebSocket bridge deployed)
# - Script 125/126 completed (GPU has RIVA model deployed)
# - GPU instance running and accessible
# ============================================================================

echo "============================================"
echo "165: Integrate Bridge with GPU"
echo "============================================"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Configuration file not found: $ENV_FILE"
    exit 1
fi

# Load configuration
source "$ENV_FILE"

# Load common functions (for resolve_gpu_ip)
COMMON_FUNCTIONS="$SCRIPT_DIR/riva-common-functions.sh"
if [ -f "$COMMON_FUNCTIONS" ]; then
    source "$COMMON_FUNCTIONS"
fi

# Required variables
REQUIRED_VARS=(
    "GPU_INSTANCE_ID"
    "RIVA_PORT"
    "SSH_KEY_NAME"
    "BRIDGE_DEPLOY_DIR"
    "APP_SSL_CERT"
    "LOG_DIR"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Required variable not set: $var"
        exit 1
    fi
done

# Auto-resolve GPU IP from instance ID
echo "Resolving GPU IP from instance ID: $GPU_INSTANCE_ID..."
GPU_INSTANCE_IP=$(resolve_gpu_ip)
if [ $? -ne 0 ] || [ -z "$GPU_INSTANCE_IP" ]; then
    echo "❌ Failed to resolve GPU IP address"
    exit 1
fi
echo "✅ Resolved GPU IP: $GPU_INSTANCE_IP"
echo ""

# SSH Configuration
SSH_KEY="$HOME/.ssh/${SSH_KEY_NAME}.pem"
SSH_OPTS="-i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
REMOTE_USER="ubuntu"

# Configuration (from .env)
BRIDGE_ENV="$BRIDGE_DEPLOY_DIR/.env"
BRIDGE_SERVICE="riva-websocket-bridge"
SSL_CERT_DIR="$(dirname "$APP_SSL_CERT")"

echo "Configuration:"
echo "  • New RIVA Host: $GPU_INSTANCE_IP"
echo "  • New RIVA Port: $RIVA_PORT"
echo "  • Bridge Directory: $BRIDGE_DEPLOY_DIR"
echo ""

# ============================================================================
# Step 1: Verify bridge deployment exists
# ============================================================================
echo "Step 1/6: Verifying WebSocket bridge deployment..."

if [ ! -d "$BRIDGE_DEPLOY_DIR" ]; then
    echo "❌ Bridge directory not found: $BRIDGE_DEPLOY_DIR"
    echo ""
    echo "The WebSocket bridge has not been deployed yet."
    echo "BRIDGE_DEPLOY_DIR is set to: $BRIDGE_DEPLOY_DIR"
    echo ""
    echo "Please deploy the WebSocket bridge first."
    exit 1
fi

if [ ! -f "$BRIDGE_ENV" ]; then
    echo "❌ Bridge .env not found: $BRIDGE_ENV"
    exit 1
fi

if ! systemctl is-enabled "$BRIDGE_SERVICE" >/dev/null 2>&1; then
    echo "❌ Service not found: $BRIDGE_SERVICE"
    echo "Bridge service is not installed as systemd service"
    exit 1
fi

echo "✅ Bridge deployment found"
echo ""

# ============================================================================
# Step 1.5: Auto-detect deployed model type
# ============================================================================
echo "Step 1.5/6: Auto-detecting deployed model..."

# Query RIVA server to detect which models are loaded
DEPLOYED_MODELS=$(ssh $SSH_OPTS "${REMOTE_USER}@${GPU_INSTANCE_IP}" \
    "curl -s -X POST http://localhost:8000/v2/repository/index 2>/dev/null" || echo "[]")

# Detect model type based on loaded models
if echo "$DEPLOYED_MODELS" | grep -qi "Parakeet"; then
    MODEL_NAME="Parakeet-RNNT-XXL-1.1b_spe1024_en-US_8.1-asr-bls-ensemble"
    ENABLE_PUNCTUATION="true"
    ENABLE_WORD_OFFSETS="false"
    MODEL_TYPE="Parakeet RNNT"
    echo "  ✅ Detected: Parakeet RNNT 1.1B"
elif echo "$DEPLOYED_MODELS" | grep -qi "conformer"; then
    MODEL_NAME="conformer-ctc-xl-en-us-streaming-asr-bls-ensemble"
    ENABLE_PUNCTUATION="false"
    ENABLE_WORD_OFFSETS="false"  # Disabled due to Conformer-CTC segfault bug
    MODEL_TYPE="Conformer-CTC"
    echo "  ✅ Detected: Conformer-CTC XL Streaming"
else
    echo "  ⚠️  Could not detect model type - using default Conformer-CTC settings"
    MODEL_NAME="conformer-ctc-xl-en-us-streaming-asr-bls-ensemble"
    ENABLE_PUNCTUATION="false"
    ENABLE_WORD_OFFSETS="false"
    MODEL_TYPE="Unknown (defaulting to Conformer-CTC)"
fi

echo "  Model: $MODEL_NAME"
echo "  Punctuation: $ENABLE_PUNCTUATION"
echo "  Word Offsets: $ENABLE_WORD_OFFSETS"
echo ""

# ============================================================================
# Step 2: Update RIVA_HOST and model config in bridge .env
# ============================================================================
echo "Step 2/6: Updating RIVA configuration in bridge..."

# Get old RIVA host for logging
OLD_RIVA_HOST=$(grep "^RIVA_HOST=" "$BRIDGE_ENV" | cut -d= -f2)
OLD_MODEL=$(grep "^RIVA_MODEL=" "$BRIDGE_ENV" | cut -d= -f2)

echo "  Old RIVA_HOST: ${OLD_RIVA_HOST:-not set}"
echo "  Old RIVA_MODEL: ${OLD_MODEL:-not set}"
echo "  New RIVA_HOST: $GPU_INSTANCE_IP"
echo "  New RIVA_MODEL: $MODEL_NAME"

# Update RIVA_HOST
sudo sed -i "s/^RIVA_HOST=.*/RIVA_HOST=$GPU_INSTANCE_IP/" "$BRIDGE_ENV"

# Update RIVA_MODEL
sudo sed -i "s|^RIVA_MODEL=.*|RIVA_MODEL=$MODEL_NAME|" "$BRIDGE_ENV"

# Update model-specific settings
sudo sed -i "s/^RIVA_ENABLE_AUTOMATIC_PUNCTUATION=.*/RIVA_ENABLE_AUTOMATIC_PUNCTUATION=$ENABLE_PUNCTUATION/" "$BRIDGE_ENV"
sudo sed -i "s/^RIVA_ENABLE_WORD_TIME_OFFSETS=.*/RIVA_ENABLE_WORD_TIME_OFFSETS=$ENABLE_WORD_OFFSETS/" "$BRIDGE_ENV"

echo "  ✅ Updated for $MODEL_TYPE"

# Verify updates
NEW_RIVA_HOST=$(sudo grep "^RIVA_HOST=" "$BRIDGE_ENV" | cut -d= -f2)
if [ "$NEW_RIVA_HOST" = "$GPU_INSTANCE_IP" ]; then
    echo "✅ RIVA_HOST updated successfully"
else
    echo "❌ Failed to update RIVA_HOST"
    exit 1
fi

echo ""

# ============================================================================
# Step 3: Fix speech_contexts compatibility
# ============================================================================
echo "Step 3/6: Fixing Conformer-CTC compatibility in riva_client.py..."

# Fix speech_contexts: change "None" to "[]" to prevent gRPC errors
RIVA_CLIENT_PY="$BRIDGE_DEPLOY_DIR/src/asr/riva_client.py"

if [ -f "$RIVA_CLIENT_PY" ]; then
    # Check if fix is needed
    if sudo grep -q '] if hotwords else None' "$RIVA_CLIENT_PY"; then
        sudo sed -i 's/] if hotwords else None/] if hotwords else []/g' "$RIVA_CLIENT_PY"
        echo "  ✅ Fixed speech_contexts: None → [] (prevents gRPC errors)"
    else
        echo "  ℹ️  speech_contexts already fixed or different version"
    fi
else
    echo "  ⚠️  riva_client.py not found at expected location"
fi

echo ""

# ============================================================================
# Step 4: Fix file permissions
# ============================================================================
echo "Step 4/6: Fixing file permissions for riva user..."

# Get the service user
SERVICE_USER=$(sudo grep "^User=" /etc/systemd/system/$BRIDGE_SERVICE.service | cut -d= -f2 || echo "riva")

echo "  Service runs as user: $SERVICE_USER"

# Fix .env permissions (readable by all)
sudo chmod 644 "$BRIDGE_ENV"

# Fix SSL cert ownership and permissions
if [ -d "$SSL_CERT_DIR" ]; then
    sudo chown -R $SERVICE_USER:$SERVICE_USER "$SSL_CERT_DIR/"
    echo "  ✅ SSL cert ownership: $SERVICE_USER:$SERVICE_USER ($SSL_CERT_DIR)"
fi

# Fix logs directory ownership
if [ -d "$LOG_DIR" ]; then
    sudo chown -R $SERVICE_USER:$SERVICE_USER "$LOG_DIR/"
    echo "  ✅ Logs ownership: $SERVICE_USER:$SERVICE_USER ($LOG_DIR)"
fi

echo "✅ Permissions fixed"
echo ""

# ============================================================================
# Step 5: Restart WebSocket bridge service
# ============================================================================
echo "Step 5/6: Restarting WebSocket bridge service..."

# Stop service
sudo systemctl stop $BRIDGE_SERVICE || true
sleep 2

# Start service (with pre-start validation)
if sudo systemctl start $BRIDGE_SERVICE; then
    echo "✅ Service started successfully"
else
    echo "❌ Service failed to start"
    echo ""
    echo "Recent logs:"
    sudo journalctl -u $BRIDGE_SERVICE -n 20 --no-pager
    exit 1
fi

sleep 3
echo ""

# ============================================================================
# Step 5: Validate service is running
# ============================================================================
echo "Step 6/6: Validating service status..."

if systemctl is-active --quiet $BRIDGE_SERVICE; then
    echo "✅ Service is active and running"

    # Show service info
    echo ""
    echo "Service Status:"
    sudo systemctl status $BRIDGE_SERVICE --no-pager | head -15

    echo ""
    echo "Recent Logs:"
    sudo journalctl -u $BRIDGE_SERVICE --since "30 seconds ago" --no-pager | tail -10
else
    echo "❌ Service is not active"
    sudo systemctl status $BRIDGE_SERVICE --no-pager
    exit 1
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================================="
echo "✅ WEBSOCKET BRIDGE UPDATED"
echo "========================================="
echo ""
echo "Bridge Configuration:"
echo "  • Old RIVA: ${OLD_RIVA_HOST}:${RIVA_PORT}"
echo "  • Old Model: ${OLD_MODEL}"
echo "  • New RIVA: ${GPU_INSTANCE_IP}:${RIVA_PORT}"
echo "  • New Model: $MODEL_NAME"
echo "  • Model Type: $MODEL_TYPE"
echo "  • Bridge Service: $BRIDGE_SERVICE"
echo "  • Service Status: $(systemctl is-active $BRIDGE_SERVICE 2>/dev/null || echo 'unknown')"
echo ""
echo "WebSocket Endpoint:"
echo "  • wss://$(curl -s http://checkip.amazonaws.com):${APP_PORT:-8443}"
echo ""
echo "Next Steps:"
echo "  • Test demo: https://$(curl -s http://checkip.amazonaws.com):${DEMO_PORT:-8444}/demo.html"
echo "  • Monitor logs: sudo journalctl -u $BRIDGE_SERVICE -f"
echo ""
