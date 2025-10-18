#!/bin/bash
#
# Script: 040-configure-edge-security.sh
# Purpose: Configure security group to allow edge machine to access GPU WhisperLive on port 9090
# Usage: ./scripts/040-configure-edge-security.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common functions if available
if [ -f "$SCRIPT_DIR/riva-common-functions.sh" ]; then
    source "$SCRIPT_DIR/riva-common-functions.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*"; }
fi

# Load environment
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
    log_info "Loaded environment from .env"
else
    log_error ".env file not found in $PROJECT_ROOT"
    exit 1
fi

# Validate required variables
if [ -z "${GPU_INSTANCE_ID:-}" ] || [ -z "${SECURITY_GROUP_ID:-}" ] || [ -z "${AWS_REGION:-}" ]; then
    log_error "Missing required environment variables: GPU_INSTANCE_ID, SECURITY_GROUP_ID, or AWS_REGION"
    exit 1
fi

log_info "==================================================================="
log_info "Configure Edge Machine Access to GPU WhisperLive (Port 9090)"
log_info "==================================================================="
log_info "GPU Instance: $GPU_INSTANCE_ID"
log_info "Security Group: $SECURITY_GROUP_ID"
log_info "Region: $AWS_REGION"
echo ""

# Get this edge machine's public IP
log_info "Getting edge machine public IP..."
EDGE_PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)

if [ -z "$EDGE_PUBLIC_IP" ]; then
    log_error "Failed to determine edge machine public IP"
    exit 1
fi

log_success "Edge machine public IP: $EDGE_PUBLIC_IP"
echo ""

# Check current security group rules for port 9090
log_info "Checking current security group rules for port 9090..."
EXISTING_RULES=$(aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`9090\` && ToPort==\`9090\`].IpRanges[].CidrIp" \
    --output text 2>/dev/null || echo "")

if echo "$EXISTING_RULES" | grep -q "${EDGE_PUBLIC_IP}/32"; then
    log_success "Edge machine ${EDGE_PUBLIC_IP}/32 already has access to port 9090"
    echo ""
    log_info "Current IPs with access to port 9090:"
    echo "$EXISTING_RULES" | tr '\t' '\n' | sed 's/^/  - /'
else
    log_warn "Edge machine ${EDGE_PUBLIC_IP}/32 does NOT have access to port 9090"
    echo ""

    if [ -n "$EXISTING_RULES" ]; then
        log_info "Current IPs with access to port 9090:"
        echo "$EXISTING_RULES" | tr '\t' '\n' | sed 's/^/  - /'
        echo ""
    fi

    # Add the security group rule
    log_info "Adding security group rule to allow ${EDGE_PUBLIC_IP}/32 on port 9090..."

    if aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --protocol tcp \
        --port 9090 \
        --cidr "${EDGE_PUBLIC_IP}/32" \
        --output json > /dev/null 2>&1; then

        log_success "Security group rule added successfully!"
    else
        log_error "Failed to add security group rule (may already exist or permission denied)"
        exit 1
    fi
fi

echo ""
log_info "==================================================================="
log_info "Testing connectivity to GPU WhisperLive..."
log_info "==================================================================="

# Test connection
if timeout 5 nc -zv "$GPU_INSTANCE_IP" 9090 2>&1 | grep -q "succeeded"; then
    log_success "✓ Successfully connected to WhisperLive on ${GPU_INSTANCE_IP}:9090"
else
    log_error "✗ Failed to connect to WhisperLive on ${GPU_INSTANCE_IP}:9090"
    log_warn "Possible issues:"
    log_warn "  1. WhisperLive is not running on the GPU instance"
    log_warn "  2. GPU instance is stopped"
    log_warn "  3. Network connectivity issue"
    exit 1
fi

echo ""
log_success "==================================================================="
log_success "Edge Security Configuration Complete!"
log_success "==================================================================="
log_info "Edge machine ${EDGE_PUBLIC_IP} can now access GPU port 9090"
log_info ""
log_info "Next steps:"
log_info "  1. Ensure WhisperLive is running on GPU: ssh to ${GPU_INSTANCE_IP} and check"
log_info "  2. Start the edge proxy: cd ~/event-b/whisper-live-test && docker compose up -d"
log_info "  3. Access the browser client at: https://${EDGE_PUBLIC_IP}/"
echo ""
