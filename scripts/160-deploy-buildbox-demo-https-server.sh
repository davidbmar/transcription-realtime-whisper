#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# 160: Deploy Build Box Demo HTTPS Server
# ============================================================================
# Deploys the demo HTTPS server systemd service on the build box.
# This serves the browser demo UI for testing WebSocket transcription.
#
# What this does:
# 1. Verify static files exist
# 2. Create systemd service for riva-http-demo on port 8444
# 3. Enable and start service
#
# Prerequisites:
# - Script 010 completed (build box setup)
# - Script 155 completed (project files copied)
# - BRIDGE_DEPLOY_DIR and DEMO_PORT set in .env
#
# The demo page will be available at:
#   https://<BUILD_BOX_IP>:8444/demo.html
# ============================================================================

echo "============================================"
echo "160: Deploy Demo HTTPS Server"
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
REQUIRED_VARS=("BRIDGE_DEPLOY_DIR" "DEMO_PORT" "DEMO_SSL_CERT" "DEMO_SSL_KEY")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo -e "${RED}❌ Required variable not set: $var${NC}"
        exit 1
    fi
done

STATIC_DIR="$BRIDGE_DEPLOY_DIR/static"
HTTPS_SERVER_SCRIPT="$BRIDGE_DEPLOY_DIR/scripts/simple_https_server.py"

echo -e "${CYAN}Configuration:${NC}"
echo "  • Static Directory: $STATIC_DIR"
echo "  • Demo Port: $DEMO_PORT"
echo "  • SSL Cert: $DEMO_SSL_CERT"
echo "  • SSL Key: $DEMO_SSL_KEY"
echo ""

# ============================================================================
# Step 1: Verify static files exist
# ============================================================================
echo -e "${BLUE}Step 1/3: Verifying static files...${NC}"

if [ ! -d "$STATIC_DIR" ]; then
    echo -e "${RED}❌ Static directory not found: $STATIC_DIR${NC}"
    echo "Run script 155 first to deploy project files."
    exit 1
fi

if [ ! -f "$STATIC_DIR/demo.html" ]; then
    echo -e "${RED}❌ demo.html not found in $STATIC_DIR${NC}"
    exit 1
fi

if [ ! -f "$HTTPS_SERVER_SCRIPT" ]; then
    echo -e "${RED}❌ HTTPS server script not found: $HTTPS_SERVER_SCRIPT${NC}"
    exit 1
fi

if [ ! -f "$DEMO_SSL_CERT" ]; then
    echo -e "${RED}❌ SSL certificate not found: $DEMO_SSL_CERT${NC}"
    exit 1
fi

if [ ! -f "$DEMO_SSL_KEY" ]; then
    echo -e "${RED}❌ SSL key not found: $DEMO_SSL_KEY${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓ Static files found${NC}"
echo -e "  ${GREEN}✓ HTTPS server script found${NC}"
echo -e "  ${GREEN}✓ SSL certificates found${NC}"
echo ""

# ============================================================================
# Step 2: Create systemd service
# ============================================================================
echo -e "${BLUE}Step 2/3: Creating systemd service...${NC}"

sudo tee /etc/systemd/system/riva-http-demo.service > /dev/null << EOF
[Unit]
Description=NVIDIA Riva HTTPS Demo Server
Documentation=https://github.com/your-org/nvidia-riva-conformer-streaming
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=$STATIC_DIR
ExecStart=/usr/bin/python3 $HTTPS_SERVER_SCRIPT $DEMO_PORT $DEMO_SSL_CERT $DEMO_SSL_KEY $STATIC_DIR
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=riva-http-demo

# Security settings
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

echo -e "  ${GREEN}✓ Service file created${NC}"
echo ""

# ============================================================================
# Step 3: Enable and start service
# ============================================================================
echo -e "${BLUE}Step 3/3: Enabling and starting service...${NC}"

# Reload systemd
sudo systemctl daemon-reload

# Enable service
sudo systemctl enable riva-http-demo

# Restart if already running (picks up new config), otherwise start fresh
if systemctl is-active --quiet riva-http-demo; then
    echo "  Service already running, restarting to pick up new config..."
    sudo systemctl restart riva-http-demo
else
    echo "  Starting service for the first time..."
    sudo systemctl start riva-http-demo
fi

# Wait a moment for service to start
sleep 2

# Check status
if systemctl is-active --quiet riva-http-demo; then
    echo -e "  ${GREEN}✓ Service is running${NC}"
else
    echo -e "  ${RED}❌ Service failed to start${NC}"
    sudo systemctl status riva-http-demo --no-pager
    exit 1
fi

echo ""

# ============================================================================
# Get build box IP
# ============================================================================
BUILD_BOX_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")

# ============================================================================
# Summary
# ============================================================================
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}✅ DEMO SERVER DEPLOYED${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Deployment Summary:"
echo "  • Service: riva-http-demo"
echo "  • Port: $DEMO_PORT"
echo "  • Static Files: $STATIC_DIR"
echo "  • Status: $(systemctl is-active riva-http-demo 2>/dev/null || echo 'unknown')"
echo ""
echo -e "${CYAN}Demo URL:${NC}"
echo "  https://$BUILD_BOX_IP:$DEMO_PORT/demo.html"
echo ""
echo -e "${YELLOW}⚠️  Next Steps:${NC}"
echo "  1. Connect bridge to GPU: ./scripts/165-integrate-buildbox-to-gpu-connection.sh"
echo "  2. Open demo URL in browser (accept self-signed cert warning)"
echo "  3. Allow microphone access and test transcription"
echo ""
echo -e "${YELLOW}Note: WebSocket bridge needs GPU connection before demo will work${NC}"
echo ""
