#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 155: Deploy Build Box WebSocket Bridge Service
# ============================================================================
# Deploys the WebSocket bridge systemd service on the build box.
# This creates the infrastructure needed to bridge browser WebSocket
# connections to the GPU RIVA gRPC server.
#
# What this does:
# 1. Copy project files to deployment directory
# 2. Create riva service user (if needed)
# 3. Create bridge .env template
# 4. Create systemd service for riva-websocket-bridge
# 5. Enable and start service
#
# Prerequisites:
# - Script 010 completed (build box setup)
# - BRIDGE_DEPLOY_DIR set in .env
# - SSL certs created (/opt/riva/certs/)
#
# Note: This script does NOT configure GPU connection.
# Run script 165 after this to connect bridge to GPU.
# ============================================================================

echo "============================================"
echo "155: Deploy WebSocket Bridge Service"
echo "============================================"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    exit 1
fi

# Load configuration
source "$ENV_FILE"

# Validate required variables
REQUIRED_VARS=("BRIDGE_DEPLOY_DIR" "APP_PORT" "RIVA_PORT" "APP_SSL_CERT" "APP_SSL_KEY" "LOG_DIR" "VENV_PYTHON")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo -e "${RED}❌ Required variable not set: $var${NC}"
        exit 1
    fi
done

echo -e "${CYAN}Configuration:${NC}"
echo "  • Deploy Directory: $BRIDGE_DEPLOY_DIR"
echo "  • WebSocket Port: $APP_PORT"
echo "  • SSL Cert: $APP_SSL_CERT"
echo "  • Log Directory: $LOG_DIR"
echo "  • Python: $VENV_PYTHON"
echo ""

# ============================================================================
# Step 1: Create riva user if needed
# ============================================================================
echo -e "${BLUE}Step 1/6: Checking riva service user...${NC}"

if ! id "riva" &>/dev/null; then
    echo "  Creating riva user..."
    sudo useradd --system --no-create-home --shell /bin/false riva
    echo -e "  ${GREEN}✓ User created${NC}"
else
    echo -e "  ${GREEN}✓ User exists${NC}"
fi
echo ""

# ============================================================================
# Step 2: Copy project files to deployment directory
# ============================================================================
echo -e "${BLUE}Step 2/6: Copying project files...${NC}"

# Create deployment directory
sudo mkdir -p "$BRIDGE_DEPLOY_DIR"
sudo mkdir -p "$BRIDGE_DEPLOY_DIR/logs"

# Copy all project files
echo "  Copying files from $PROJECT_ROOT to $BRIDGE_DEPLOY_DIR..."
sudo rsync -a --exclude='.git' --exclude='logs/*' --exclude='venv' \
    "$PROJECT_ROOT/" "$BRIDGE_DEPLOY_DIR/"

echo -e "  ${GREEN}✓ Files copied${NC}"
echo ""

# ============================================================================
# Step 3: Create bridge .env template
# ============================================================================
echo -e "${BLUE}Step 3/6: Creating bridge .env template...${NC}"

sudo tee "$BRIDGE_DEPLOY_DIR/.env" > /dev/null << EOF
# WebSocket Bridge Configuration
# This file will be updated by script 165 to point to GPU

# RIVA Server Connection (will be auto-configured)
RIVA_HOST=localhost
RIVA_PORT=$RIVA_PORT
RIVA_MODEL=conformer-ctc-xl-en-us-streaming-asr-bls-ensemble

# Model Configuration
RIVA_ENABLE_AUTOMATIC_PUNCTUATION=false
RIVA_ENABLE_WORD_TIME_OFFSETS=false

# WebSocket Server
APP_HOST=0.0.0.0
APP_PORT=$APP_PORT

# SSL Configuration
APP_SSL_CERT=$APP_SSL_CERT
APP_SSL_KEY=$APP_SSL_KEY

# Logging
LOG_LEVEL=INFO
LOG_DIR=$LOG_DIR
EOF

echo -e "  ${GREEN}✓ Template created at $BRIDGE_DEPLOY_DIR/.env${NC}"
echo ""

# ============================================================================
# Step 4: Fix permissions
# ============================================================================
echo -e "${BLUE}Step 4/6: Setting permissions...${NC}"

# Set ownership
sudo chown -R riva:riva "$BRIDGE_DEPLOY_DIR"
sudo chown -R riva:riva "$LOG_DIR"
sudo chown -R riva:riva "$(dirname "$APP_SSL_CERT")"

# Make .env readable
sudo chmod 644 "$BRIDGE_DEPLOY_DIR/.env"

echo -e "  ${GREEN}✓ Permissions set${NC}"
echo ""

# ============================================================================
# Step 5: Create systemd service
# ============================================================================
echo -e "${BLUE}Step 5/6: Creating systemd service...${NC}"

sudo tee /etc/systemd/system/riva-websocket-bridge.service > /dev/null << EOF
[Unit]
Description=NVIDIA Riva WebSocket Bridge Server
Documentation=https://github.com/your-org/nvidia-riva-conformer-streaming
After=network.target
Wants=network.target

[Service]
Type=simple
User=riva
Group=riva
WorkingDirectory=$BRIDGE_DEPLOY_DIR
Environment=PYTHONPATH=$BRIDGE_DEPLOY_DIR
EnvironmentFile=$BRIDGE_DEPLOY_DIR/.env

# Main service command
ExecStart=$VENV_PYTHON -m src.asr.riva_websocket_bridge

# Pre-start validation
ExecStartPre=/bin/bash -c 'source $BRIDGE_DEPLOY_DIR/.env && \\
    echo "Validating Riva connection to \$\${RIVA_HOST}:\$\${RIVA_PORT}..." && \\
    timeout 10 nc -z \$\${RIVA_HOST} \$\${RIVA_PORT} || \\
    (echo "ERROR: Cannot connect to Riva server at \$\${RIVA_HOST}:\$\${RIVA_PORT}" && exit 1)'

# Graceful shutdown
ExecStop=/bin/kill -SIGTERM \$MAINPID
TimeoutStopSec=30
KillMode=mixed

# Restart policy
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$LOG_DIR $BRIDGE_DEPLOY_DIR/logs /tmp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=riva-websocket-bridge

# Health monitoring
ExecReload=/bin/kill -SIGHUP \$MAINPID

[Install]
WantedBy=multi-user.target
Alias=riva-bridge.service
EOF

echo -e "  ${GREEN}✓ Service file created${NC}"
echo ""

# ============================================================================
# Step 6: Enable and start service
# ============================================================================
echo -e "${BLUE}Step 6/6: Enabling and starting service...${NC}"

# Reload systemd
sudo systemctl daemon-reload

# Enable service
sudo systemctl enable riva-websocket-bridge

echo -e "  ${YELLOW}Note: Service will fail to start until GPU connection is configured${NC}"
echo -e "  ${YELLOW}Run script 165 to connect bridge to GPU${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}✅ WEBSOCKET BRIDGE DEPLOYED${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Deployment Summary:"
echo "  • Deploy Directory: $BRIDGE_DEPLOY_DIR"
echo "  • Service: riva-websocket-bridge"
echo "  • WebSocket Port: $APP_PORT"
echo "  • User: riva"
echo ""
echo -e "${YELLOW}⚠️  Next Steps:${NC}"
echo "  1. Deploy demo server: ./scripts/160-deploy-buildbox-demo-https-server.sh"
echo "  2. Connect to GPU: ./scripts/165-integrate-buildbox-to-gpu-connection.sh"
echo ""
echo "The bridge service is deployed but NOT started (needs GPU connection)."
echo ""
