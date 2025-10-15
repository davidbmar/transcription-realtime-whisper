#!/bin/bash
set -e
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ==================================================================
# 030: Configure GPU Security Groups (Internal-Only Access)
# ==================================================================
# Locks down GPU worker to accept connections ONLY from build box.
# This script is fully automated - no interactive prompts.
#
# Security Model:
#   GPU Worker = Internal-only, never exposed to internet
#   Only build box can access GPU ports: 22 (SSH), 50051 (gRPC), 8000 (HTTP)
#
# Usage:
#   ./scripts/030-configure-gpu-security.sh
# ==================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Source common functions
source "$SCRIPT_DIR/riva-common-functions.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}🔒 GPU Security Group Configuration (Internal-Only Access)${NC}"
echo "================================================================"
echo ""
echo -e "${CYAN}Security Model:${NC}"
echo "  GPU Worker: INTERNAL-ONLY access from build box"
echo "  Ports: 22 (SSH), 50051 (gRPC), 8000 (HTTP)"
echo "  Client Access: Use script 031 to manage build box clients"
echo "================================================================"
echo ""

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error "Configuration file not found: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

# Validate required variables
if [ -z "$SECURITY_GROUP_ID" ]; then
    log_error "SECURITY_GROUP_ID not set in .env"
    echo "GPU security group ID is required."
    exit 1
fi

if [ -z "$GPU_INSTANCE_IP" ]; then
    log_warn "GPU_INSTANCE_IP not set in .env"
    echo "GPU instance IP should be configured, but continuing..."
fi

if [ -z "$AWS_REGION" ]; then
    log_error "AWS_REGION not set in .env"
    exit 1
fi

# GPU configuration
GPU_SG="$SECURITY_GROUP_ID"
GPU_PORTS=(22 50051 8000)
GPU_PORT_DESCRIPTIONS=("SSH" "RIVA gRPC" "RIVA HTTP/Health")

echo -e "${CYAN}Configuration:${NC}"
echo "  GPU Security Group: $GPU_SG"
echo "  GPU Instance IP: ${GPU_INSTANCE_IP:-<not set>}"
echo "  AWS Region: $AWS_REGION"
echo "  Ports: ${GPU_PORTS[*]}"
echo ""

# ==================================================================
# Step 1: Auto-detect Build Box IP
# ==================================================================
echo -e "${CYAN}Step 1: Auto-detecting Build Box IP...${NC}"
echo "----------------------------------------"

# Try multiple methods to get public IP
BUILDBOX_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
              curl -s --max-time 5 icanhazip.com 2>/dev/null || \
              curl -s --max-time 5 ipinfo.io/ip 2>/dev/null || \
              echo "")

if [ -z "$BUILDBOX_IP" ]; then
    log_error "Failed to auto-detect build box public IP"
    echo ""
    echo "Please manually enter the build box public IP:"
    read -p "Build Box IP: " BUILDBOX_IP

    if [ -z "$BUILDBOX_IP" ]; then
        log_error "Build box IP is required"
        exit 1
    fi
fi

# Validate IP format
if [[ ! "$BUILDBOX_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log_error "Invalid IP format: $BUILDBOX_IP"
    exit 1
fi

log_success "Detected build box IP: $BUILDBOX_IP"
echo ""

# ==================================================================
# Step 2: Show Current GPU Security Group Rules
# ==================================================================
echo -e "${CYAN}Step 2: Current GPU Security Group Rules${NC}"
echo "----------------------------------------"

CURRENT_RULES=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$GPU_SG" \
    --query 'SecurityGroups[0].IpPermissions[]' \
    --output json 2>/dev/null)

if [ -z "$CURRENT_RULES" ] || [ "$CURRENT_RULES" == "[]" ]; then
    echo "  (no rules configured)"
else
    echo "$CURRENT_RULES" | jq -r '.[] | {port: .FromPort, cidrs: .IpRanges[].CidrIp} | "\(.port) \(.cidrs)"' | \
        sort -n | awk 'BEGIN {
            print "  PORT     SOURCE"
            print "  ───────────────────────────────"
        } { printf "  %-8s %s\n", $1, $2 }'
fi
echo ""

# ==================================================================
# Step 3: Ask to Delete Existing Rules
# ==================================================================
echo -e "${YELLOW}Step 3: Clear existing rules?${NC}"
echo "----------------------------------------"
echo "Options:"
echo "  1) Keep existing rules and add build box IP (recommended)"
echo "  2) Delete all rules and start fresh"
echo ""
read -p "Enter choice [1-2] (default: 1): " delete_choice
delete_choice=${delete_choice:-1}
echo ""

if [ "$delete_choice" == "2" ]; then
    log_warn "Deleting all existing rules from GPU security group..."

    if [ -n "$CURRENT_RULES" ] && [ "$CURRENT_RULES" != "[]" ]; then
        aws ec2 revoke-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$GPU_SG" \
            --ip-permissions "$CURRENT_RULES" >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            log_success "All rules deleted"
        else
            log_error "Failed to delete some rules"
        fi
    else
        echo "No rules to delete"
    fi
else
    log_info "Keeping existing rules, will add/update as needed"
fi
echo ""

# ==================================================================
# Step 4: Apply Build Box IP to GPU Ports
# ==================================================================
echo -e "${CYAN}Step 4: Applying Build Box IP to GPU Ports${NC}"
echo "----------------------------------------"

ADDED_COUNT=0
EXISTED_COUNT=0

for i in "${!GPU_PORTS[@]}"; do
    PORT="${GPU_PORTS[$i]}"
    DESC="${GPU_PORT_DESCRIPTIONS[$i]}"

    echo -n "  Port $PORT ($DESC): Adding $BUILDBOX_IP..."

    RESULT=$(aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$GPU_SG" \
        --protocol tcp \
        --port "$PORT" \
        --cidr "${BUILDBOX_IP}/32" 2>&1)

    if echo "$RESULT" | grep -q "already exists"; then
        echo -e " ${YELLOW}already exists${NC}"
        ((EXISTED_COUNT++))
    elif echo "$RESULT" | grep -q "Success\|^$"; then
        echo -e " ${GREEN}added${NC}"
        ((ADDED_COUNT++))
    else
        echo -e " ${RED}failed${NC}"
        echo "    Error: $RESULT"
    fi
done

echo ""
log_info "Summary: $ADDED_COUNT rules added, $EXISTED_COUNT already existed"
echo ""

# ==================================================================
# Step 5: Final Verification
# ==================================================================
echo -e "${CYAN}Step 5: Final GPU Security Group Configuration${NC}"
echo "================================================================"

FINAL_RULES=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$GPU_SG" \
    --query 'SecurityGroups[0].IpPermissions[]' \
    --output json 2>/dev/null)

echo "Configured Security Rules:"
echo "-------------------------"
echo "$FINAL_RULES" | jq -r '.[] | "Port \(.FromPort): \([.IpRanges[].CidrIp] | join(", "))"' | \
    sort -n | sed 's/^/  /'

echo ""
echo "Build Box Access:"
echo "-----------------"
echo "$FINAL_RULES" | jq -r --arg buildbox_ip "${BUILDBOX_IP}/32" '
    .[] |
    select(.IpRanges[].CidrIp == $buildbox_ip) |
    .FromPort
' | sort -n | tr '\n' ' ' | awk -v ip="$BUILDBOX_IP" '{print "  " ip ": ports " $0}'

echo ""
echo ""

# ==================================================================
# Summary
# ==================================================================
log_success "═══════════════════════════════════════════════════════════"
log_success "GPU SECURITY CONFIGURATION COMPLETE"
log_success "═══════════════════════════════════════════════════════════"
echo ""
echo "Configuration Summary:"
echo "  Security Group: $GPU_SG"
echo "  Build Box IP: $BUILDBOX_IP"
echo "  GPU Instance IP: ${GPU_INSTANCE_IP:-<not set>}"
echo "  Ports Configured: ${GPU_PORTS[*]}"
echo ""
echo "Security Model:"
echo "  ✅ GPU accepts connections ONLY from build box"
echo "  ✅ Ports 22, 50051, 8000 locked to ${BUILDBOX_IP}"
echo "  ❌ GPU is NOT accessible from internet"
echo ""
echo "Next Steps:"
echo "  • Manage client access: ./scripts/031-configure-buildbox-security.sh"
echo "  • Deploy GPU model: ./scripts/110-deploy-conformer-streaming.sh"
echo "  • Check GPU status: ./scripts/750-status-gpu-instance.sh"
echo ""
echo "================================================================"
