#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 220: Startup GPU and Restore Working State
# ============================================================================
# Complete one-command restoration of WhisperLive streaming setup.
# Run this after shutting down the GPU to save costs.
#
# What this does:
# 1. Starts GPU EC2 instance (uses GPU_INSTANCE_ID from .env)
# 2. Waits for instance to be ready
# 3. Queries AWS for current IP (IP changes on every stop/start)
# 4. If IP changed, updates ALL config files:
#    - .env (GPU_INSTANCE_IP, RIVA_HOST)
#    - .env-http (DOMAIN, GPU_HOST)
# 5. If IP changed, updates AWS security groups
# 6. If IP changed, recreates Docker containers (Caddy) to load new IP
# 7. Verifies SSH connectivity
# 8. Checks WhisperLive service status
# 9. Deploys WhisperLive if needed
# 10. Runs full health check
#
# Architecture: Instance ID is source of truth, IP is resolved at startup
# Total time: 5-10 minutes (2min startup + 3-8min deployment if needed)
# ============================================================================

source "$(dirname "$0")/riva-common-functions.sh"
load_environment

# Validate GPU_INSTANCE_ID is set
if [ -z "${GPU_INSTANCE_ID:-}" ]; then
    log_error "❌ GPU_INSTANCE_ID not set in .env"
    echo ""
    echo "To fix this, you have two options:"
    echo ""
    echo "Option 1: Use an existing GPU instance"
    echo "  1. List available GPUs:"
    echo "     aws ec2 describe-instances --region us-east-2 --filters \"Name=instance-type,Values=g4dn.*\" --output table"
    echo ""
    echo "  2. Start the GPU and set instance ID:"
    echo "     ./scripts/730-start-gpu-instance.sh --instance-id i-XXXXXXXXX"
    echo "     (This will update .env with GPU_INSTANCE_ID)"
    echo ""
    echo "Option 2: Create a new GPU instance"
    echo "  ./scripts/020-deploy-gpu-instance.sh"
    echo ""
    exit 1
fi

REGION="${AWS_REGION:-us-east-2}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/dbm-sep23-2025.pem}"

log_info "🚀 Starting GPU and restoring Conformer-CTC streaming"
log_info "Instance: $GPU_INSTANCE_ID"
echo ""

# ============================================================================
# Step 1: Start GPU Instance
# ============================================================================
log_info "Step 1/6: Starting GPU instance..."
STATE=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

if [ "$STATE" = "running" ]; then
  log_success "✅ Instance already running"
else
  log_info "Current state: $STATE, starting..."
  aws ec2 start-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$REGION" \
    --output text > /dev/null

  log_info "Waiting for instance to start (2-3 minutes)..."
  aws ec2 wait instance-running \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$REGION"

  log_success "✅ Instance started"

  # Give the instance extra time to fully boot
  log_info "Waiting 30s for instance to fully boot..."
  sleep 30
fi

echo ""

# ============================================================================
# Step 2: Get Current IP and Update .env if Changed
# ============================================================================
log_info "Step 2/6: Checking GPU IP address..."
CURRENT_IP=$(aws ec2 describe-instances \
  --instance-ids "$GPU_INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log_info "Current GPU IP: $CURRENT_IP"

OLD_IP=$(grep "^GPU_INSTANCE_IP=" .env | cut -d'=' -f2)

if [ "$CURRENT_IP" != "$OLD_IP" ]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║                                                            ║"
  echo "║         ⚠️  CRITICAL: GPU IP ADDRESS HAS CHANGED          ║"
  echo "║                                                            ║"
  echo "╟────────────────────────────────────────────────────────────╢"
  echo "║  Old IP: $OLD_IP"
  echo "║  New IP: $CURRENT_IP"
  echo "╟────────────────────────────────────────────────────────────╢"
  echo "║  Actions being taken:                                      ║"
  echo "║   1. Updating all config files (.env, .env-http)           ║"
  echo "║   2. Exporting environment variables                       ║"
  echo "║   3. Reloading configuration                               ║"
  echo "║   4. Updating AWS security groups                          ║"
  echo "║   5. Recreating Docker containers (Caddy)                  ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  log_info "Step 1/5: Updating configuration files..."

  # Update .env
  sed -i "s/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=$CURRENT_IP/" .env
  sed -i "s/^RIVA_HOST=.*/RIVA_HOST=$CURRENT_IP/" .env
  log_success "  ✅ .env updated"

  # Update .env-http (for WhisperLive edge proxy)
  if [ -f .env-http ]; then
    sed -i "s/^DOMAIN=.*/DOMAIN=$CURRENT_IP/" .env-http
    sed -i "s/^GPU_HOST=.*/GPU_HOST=$CURRENT_IP/" .env-http
    log_success "  ✅ .env-http updated"
  fi

  log_success "✅ All configuration files updated"

  log_info "Step 2/5: Exporting environment variables..."
  export GPU_INSTANCE_IP="$CURRENT_IP"
  export RIVA_HOST="$CURRENT_IP"
  log_success "✅ Variables exported for child scripts"

  log_info "Step 3/5: Reloading .env configuration..."
  load_environment
  log_success "✅ Configuration reloaded"

  log_info "Step 4/5: Updating AWS security groups..."
  if echo "1" | "$(dirname "$0")/030-configure-gpu-security.sh" > /dev/null 2>&1; then
    log_success "✅ Security groups updated successfully"
  else
    log_warn "⚠️  Security group update encountered issues"
    log_info "You may need to run manually: ./scripts/030-configure-gpu-security.sh"
  fi

  echo ""
  log_info "Step 5/5: Recreating Docker containers with new IP..."

  # Recreate Caddy container to pick up new GPU_HOST from .env-http
  if [ -f docker-compose.yml ]; then
    log_info "  Stopping Caddy container..."
    docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true

    log_info "  Starting Caddy with updated GPU IP..."
    if docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null; then
      log_success "  ✅ Caddy container recreated"
    else
      log_warn "  ⚠️  Failed to recreate Caddy container"
    fi
  fi

  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║                                                            ║"
  echo "║    ✅ IP CHANGE COMPLETE - CONTINUING WITH DEPLOYMENT     ║"
  echo "║                                                            ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
else
  log_success "✅ IP unchanged: $CURRENT_IP"
fi

echo ""

# ============================================================================
# Step 3: Check SSH Connectivity
# ============================================================================
log_info "Step 3/6: Verifying SSH connectivity..."
RETRY=0
MAX_RETRIES=10

while [ $RETRY -lt $MAX_RETRIES ]; do
  if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
     ubuntu@"$CURRENT_IP" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
    log_success "✅ SSH connected"
    break
  fi
  RETRY=$((RETRY + 1))
  log_info "SSH not ready, retrying ($RETRY/$MAX_RETRIES)..."
  sleep 10
done

if [ $RETRY -eq $MAX_RETRIES ]; then
  log_error "❌ SSH connection failed after $MAX_RETRIES attempts"
  exit 1
fi

echo ""

# ============================================================================
# Step 4: Check if RIVA Server is Running
# ============================================================================
log_info "Step 4/6: Checking RIVA server status..."

RIVA_READY=$(ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" \
  'curl -sf http://localhost:8000/v2/health/ready && echo READY || echo NOT_READY' 2>/dev/null || echo "NOT_READY")

if [ "$RIVA_READY" = "READY" ]; then
  log_success "✅ RIVA server already running and ready"

  # Verify correct model is loaded
  log_info "Verifying Conformer-CTC model is loaded..."
  MODEL_CHECK=$(ssh -i "$SSH_KEY" ubuntu@"$CURRENT_IP" \
    'curl -s -X POST http://localhost:8000/v2/repository/index -H "Content-Type: application/json" -d "{}" | grep -c "conformer-ctc-xl-en-us-streaming"' || echo "0")

  if [ "$MODEL_CHECK" -gt "0" ]; then
    log_success "✅ Conformer-CTC model loaded"
    NEEDS_DEPLOY=false
  else
    log_warn "⚠️  Conformer-CTC model not loaded, will deploy"
    NEEDS_DEPLOY=true
  fi
else
  log_warn "⚠️  RIVA server not running, will deploy"
  NEEDS_DEPLOY=true
fi

echo ""

# ============================================================================
# Step 5: Deploy Conformer-CTC if Needed
# ============================================================================
if [ "$NEEDS_DEPLOY" = "true" ]; then
  log_info "Step 5/6: Deploying Conformer-CTC streaming model..."
  log_info "This will take 5-10 minutes..."
  echo ""

  # Run deployment script
  "$(dirname "$0")/110-deploy-conformer-streaming.sh"

  log_success "✅ Deployment complete"
else
  log_info "Step 5/6: Skipping deployment (already running)"
fi

echo ""

# ============================================================================
# Step 6: Restart WebSocket Bridge
# ============================================================================
log_info "Step 6/6: Restarting WebSocket bridge..."
sudo systemctl restart riva-websocket-bridge
sleep 3

BRIDGE_STATUS=$(sudo systemctl is-active riva-websocket-bridge || echo "inactive")
if [ "$BRIDGE_STATUS" = "active" ]; then
  log_success "✅ WebSocket bridge running"
else
  log_error "❌ WebSocket bridge failed to start"
  sudo journalctl -u riva-websocket-bridge -n 20 --no-pager
  exit 1
fi

echo ""

# ============================================================================
# Final Health Check
# ============================================================================
log_success "========================================="
log_success "✅ SYSTEM READY"
log_success "========================================="
echo ""
log_info "📊 Status Summary:"
echo "  GPU Instance: $GPU_INSTANCE_ID"
echo "  GPU IP: $CURRENT_IP"
echo "  RIVA Server: READY (http://$CURRENT_IP:8000)"
echo "  WebSocket Bridge: RUNNING (wss://${BUILDBOX_PUBLIC_IP:-3.16.124.227}:${APP_PORT:-8443})"
echo "  HTTPS Demo: https://${BUILDBOX_PUBLIC_IP:-3.16.124.227}:${DEMO_PORT:-8444}/demo.html"
echo ""
log_info "🧪 Test it now:"
echo "  1. Open: https://${BUILDBOX_PUBLIC_IP:-3.16.124.227}:${DEMO_PORT:-8444}/demo.html"
echo "  2. Click 'Start Transcription'"
echo "  3. Speak into microphone"
echo "  4. See real-time transcriptions"
echo ""
log_info "📝 Check logs:"
echo "  sudo journalctl -u riva-websocket-bridge -f"
echo ""
log_success "🎉 You're back in business!"
