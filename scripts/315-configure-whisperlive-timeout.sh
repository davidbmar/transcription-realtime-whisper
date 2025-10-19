#!/bin/bash
set -euo pipefail

# ============================================================================
# Script 315: Configure WhisperLive Connection Timeout
# ============================================================================
#
# PURPOSE:
# --------
# WhisperLive has a built-in connection timeout that automatically disconnects
# clients after a specified duration. This is a time-based limit (not silence-
# based) designed to prevent resource hogging and manage GPU memory.
#
# SYMPTOM:
# --------
# Users experience automatic disconnection after recording for some time,
# regardless of whether they're speaking or silent. The browser shows:
#   "WebSocket closed. Code: 1006 Reason:"
#
# ROOT CAUSE:
# -----------
# WhisperLive server has a max_connection_time parameter that defaults to
# 600 seconds (10 minutes). After this time, the server forcibly disconnects
# the client with a warning:
#   "Client disconnected due to overtime."
#
# This is NOT a bug - it's a deliberate design feature in WhisperLive to:
#   1. Prevent single clients from monopolizing GPU resources
#   2. Free up connections for other users
#   3. Limit GPU memory usage over long sessions
#
# SOLUTION:
# ---------
# Increase the max_connection_time parameter to a higher value based on
# your use case:
#   - 600 seconds (10 min)  = Default, good for quick demos
#   - 1800 seconds (30 min) = Comfortable for meetings
#   - 3600 seconds (1 hour) = Recommended for general use
#   - 7200 seconds (2 hours) = Long recording sessions
#   - 86400 seconds (24 hours) = Essentially unlimited
#
# TRADE-OFFS:
# -----------
# Longer timeout:
#   ✅ Better user experience (fewer disconnects)
#   ✅ Suitable for long-form content (lectures, interviews)
#   ⚠️  May allow clients to hold GPU resources when inactive
#   ⚠️  Could reduce available slots for new connections
#
# Shorter timeout:
#   ✅ Faster turnover of client connections
#   ✅ Better resource management with many users
#   ⚠️  Frequent disconnections during long sessions
#   ⚠️  Poor user experience for extended use
#
# TECHNICAL DETAILS:
# ------------------
# The timeout is implemented in WhisperLive's server.py:
#   - ClientManager tracks connection start time per WebSocket
#   - Every audio frame processing checks: elapsed_time >= max_connection_time
#   - If exceeded, calls client.disconnect() and logs warning
#   - Browser receives WebSocket close event (code 1006)
#
# This script modifies the systemd service to add --max_connection_time flag
# to the WhisperLive server startup command.
#
# ============================================================================

source "$(dirname "$0")/riva-common-functions.sh"
load_environment

# Configuration
TIMEOUT_SECONDS="${1:-3600}"  # Default: 1 hour (3600 seconds)
SERVICE_NAME="whisperlive"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log_info "🔧 Configuring WhisperLive Connection Timeout"
echo ""

# Validate input
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_error "❌ Invalid timeout value: $TIMEOUT_SECONDS"
    echo "Usage: $0 [timeout_in_seconds]"
    echo ""
    echo "Examples:"
    echo "  $0 1800   # 30 minutes"
    echo "  $0 3600   # 1 hour (recommended)"
    echo "  $0 7200   # 2 hours"
    exit 1
fi

# Convert to human-readable
HOURS=$((TIMEOUT_SECONDS / 3600))
MINUTES=$(((TIMEOUT_SECONDS % 3600) / 60))
SECONDS=$((TIMEOUT_SECONDS % 60))

log_info "Configuration:"
echo "  Timeout: $TIMEOUT_SECONDS seconds"
if [ $HOURS -gt 0 ]; then
    echo "  Human-readable: ${HOURS}h ${MINUTES}m ${SECONDS}s"
elif [ $MINUTES -gt 0 ]; then
    echo "  Human-readable: ${MINUTES}m ${SECONDS}s"
else
    echo "  Human-readable: ${SECONDS}s"
fi
echo ""

# Check if WhisperLive is installed
if ! ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" "test -f /home/ubuntu/whisperlive/WhisperLive/run_server.py" 2>/dev/null; then
    log_error "❌ WhisperLive not found on GPU instance"
    echo "Run ./scripts/310-configure-whisperlive-gpu.sh first"
    exit 1
fi

# Backup current service file
log_info "Step 1/4: Backing up current service file..."
ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" \
    "sudo cp $SERVICE_FILE ${SERVICE_FILE}.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
log_success "✅ Backup created"

echo ""
log_info "Step 2/4: Updating systemd service configuration..."

# Update service file on GPU
ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" bash <<EOF
set -e

# Create new service file with timeout parameter
sudo tee $SERVICE_FILE > /dev/null <<'SERVICE'
[Unit]
Description=WhisperLive WebSocket Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/whisperlive/WhisperLive
Environment="PATH=/home/ubuntu/whisperlive/WhisperLive/venv/bin"
Environment="LD_LIBRARY_PATH=/home/ubuntu/whisperlive/WhisperLive/venv/lib/python3.9/site-packages/nvidia/cudnn/lib:/home/ubuntu/whisperlive/WhisperLive/venv/lib/python3.9/site-packages/nvidia/cublas/lib"
ExecStart=/home/ubuntu/whisperlive/WhisperLive/venv/bin/python3 run_server.py \\
    --port 9090 \\
    --backend faster_whisper \\
    --max_connection_time $TIMEOUT_SECONDS

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

echo "Service file updated with timeout: $TIMEOUT_SECONDS seconds"
EOF

log_success "✅ Service file updated"

echo ""
log_info "Step 3/4: Reloading systemd daemon..."
ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl daemon-reload"
log_success "✅ Systemd reloaded"

echo ""
log_info "Step 4/4: Restarting WhisperLive service..."
ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl restart $SERVICE_NAME"

# Wait for service to start
sleep 3

# Verify service is running
SERVICE_STATUS=$(ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl is-active $SERVICE_NAME" 2>/dev/null || echo "failed")

if [ "$SERVICE_STATUS" = "active" ]; then
    log_success "✅ WhisperLive service restarted successfully"
else
    log_error "❌ Service failed to start"
    echo ""
    echo "Check logs:"
    echo "  ssh -i $SSH_KEY ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u $SERVICE_NAME -n 50'"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
echo "║         ✅ TIMEOUT CONFIGURATION COMPLETE                 ║"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
log_info "Summary:"
echo "  • Connection timeout: $TIMEOUT_SECONDS seconds"
if [ $HOURS -gt 0 ]; then
    echo "  • Duration: ${HOURS}h ${MINUTES}m ${SECONDS}s"
elif [ $MINUTES -gt 0 ]; then
    echo "  • Duration: ${MINUTES}m ${SECONDS}s"
else
    echo "  • Duration: ${SECONDS}s"
fi
echo "  • Service status: $SERVICE_STATUS"
echo ""
log_info "What this means:"
echo "  • Browser clients will stay connected for up to $(echo "$HOURS hours $MINUTES minutes" | sed 's/^0 hours //')"
echo "  • After timeout, clients will be automatically disconnected"
echo "  • Users can simply click 'Start Recording' again to reconnect"
echo ""
log_info "To change timeout again:"
echo "  $0 [seconds]"
echo ""
log_info "Examples:"
echo "  $0 1800   # 30 minutes"
echo "  $0 7200   # 2 hours"
echo ""
