# Real-Time Speech Transcription System

**Production-ready real-time speech recognition with dual architecture support: NVIDIA Riva and WhisperLive**

[![Architecture](https://img.shields.io/badge/Architecture-Multi--Cloud-blue)](https://github.com/davidbmar/transcription-realtime-whisper)
[![GPU](https://img.shields.io/badge/GPU-NVIDIA%20T4-green)](https://aws.amazon.com/ec2/instance-types/g4/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Setup Scripts (000-040)](#setup-scripts-000-040)
- [WhisperLive Edge Deployment (300-320)](#whisperlive-edge-deployment-300-320)
- [Browser Clients](#browser-clients)
- [Critical Technical Details](#critical-technical-details)
- [Cost Optimization](#cost-optimization)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)

## Overview

This repository provides complete deployment automation for **two real-time speech recognition architectures**:

### 🎯 WhisperLive Edge Proxy (Recommended - Quick Start)
- **Open-source** Whisper streaming ASR
- **Edge proxy** with Caddy reverse proxy + SSL termination
- **20 minutes** to production
- **No API keys** required
- **Multi-language** support

### 🎯 NVIDIA Riva Conformer-CTC (Enterprise)
- **Enterprise-grade** accuracy and performance
- **NVIDIA Riva 2.19** with Conformer-CTC-XL streaming
- **Low latency** with 40ms timesteps
- **gRPC** protocol
- **Requires** NVIDIA NGC API key

Both systems support:
- ✅ Real-time browser-based transcription
- ✅ Secure HTTPS/WSS connections
- ✅ GPU acceleration (AWS g4dn.xlarge)
- ✅ Systemd service management
- ✅ Auto-restart and health checks
- ✅ Production-ready deployment

## Architecture

### WhisperLive Edge Proxy Architecture

```
┌─────────────────┐      HTTPS/WSS       ┌──────────────────┐      WebSocket      ┌─────────────────┐
│                 │────────:443─────────▶│                  │──────:9090────────▶│                 │
│  Browser Client │                      │   Edge EC2       │                     │   GPU EC2       │
│  (Your Mac)     │                      │   Caddy Proxy    │                     │   WhisperLive   │
│                 │◀─── Transcriptions ──│   SSL Termination│◀── Transcriptions ──│   faster-whisper│
└─────────────────┘                      └──────────────────┘                     └─────────────────┘
      │                                          │                                         │
      │ Microphone                               │ Reverse Proxy                          │
      │ Float32 PCM @ 16kHz                      │ Public IP                              │ Private IP
      │ Mono Audio                               │ Ports: 80, 443                         │ Port: 9090
      │                                          │                                         │
      └──────────────────────────────────────────┴─────────────────────────────────────────┘
                                    Secure Edge → GPU Communication
```

**Components:**
- **Browser Client**: AudioContext → Float32 PCM → WebSocket
- **Edge EC2**: Caddy reverse proxy with SSL certificates (public-facing)
- **GPU EC2**: WhisperLive service with faster-whisper (internal-only)

**Security Model:**
- Edge EC2 is public-facing with SSL termination
- GPU EC2 is private (only accessible from Edge)
- Client allowlist managed via security groups

### NVIDIA Riva Architecture

```
┌─────────────────┐      WSS/HTTPS      ┌──────────────────┐        gRPC        ┌─────────────────┐
│                 │────────:8443────────▶│                  │───────:50051──────▶│                 │
│  Browser Client │        :8444         │   Build Box      │                    │   GPU EC2       │
│                 │◀─── Transcriptions ──│   WebSocket      │◀── Transcriptions ─│   RIVA 2.19     │
│                 │                      │   Bridge         │                    │   Conformer-CTC │
└─────────────────┘                      └──────────────────┘                    └─────────────────┘
```

**Components:**
- **Build Box**: Python WebSocket bridge (WSS → gRPC conversion)
- **GPU EC2**: NVIDIA Riva Docker container with Conformer-CTC-XL model

## Quick Start

### Prerequisites

- **AWS Account** with EC2 permissions
- **SSH Key Pair** (default: `dbm-sep23-2025`)
- **Modern Browser** (Chrome, Firefox, Edge)
- For Riva: **NVIDIA NGC API Key** from https://ngc.nvidia.com
- **30-40 minutes** for complete deployment

### Deployment Path: WhisperLive Edge (Fastest)

This is the recommended path for getting started quickly:

```bash
# 1. Clone repository
git clone https://github.com/davidbmar/transcription-realtime-whisper.git
cd transcription-realtime-whisper

# 2. Initial setup (000-040)
./scripts/010-setup-build-box.sh             # 5 min - Install dependencies
./scripts/020-deploy-gpu-instance.sh         # 10 min - Create GPU instance

# 3. WhisperLive deployment (300-320) - DEFAULT
./scripts/305-setup-whisperlive-edge.sh      # 5 min - Setup edge proxy
./scripts/310-configure-whisperlive-gpu.sh   # 10 min - Install WhisperLive on GPU
./scripts/030-configure-gpu-security.sh      # 1 min - Allow edge→GPU access (port 9090)
./scripts/031-configure-edge-box-security.sh # 1 min - Manage client access (ports 80, 443)
./scripts/320-update-edge-clients.sh         # 1 min - Deploy browser UI
./scripts/315-test-whisperlive-connection.sh # 1 min - Validate

# 4. Open in browser
open https://YOUR_EDGE_IP/
```

**Total time: ~20 minutes**

### Deployment Path: NVIDIA Riva (Enterprise)

For enterprise-grade accuracy with NVIDIA Riva:

```bash
# After initial setup, deploy Riva with --riva flag:
./scripts/030-configure-gpu-security.sh --riva          # Ports 50051, 8000
./scripts/031-configure-edge-box-security.sh --riva     # Ports 8443, 8444
./scripts/125-deploy-conformer-from-s3-cache.sh
./scripts/126-validate-conformer-deployment.sh
./scripts/155-deploy-buildbox-websocket-bridge-service.sh
./scripts/160-deploy-buildbox-demo-https-server.sh

# Open in browser
open https://BUILD_BOX_IP:8444/demo.html
```

**Total time: ~40 minutes** (includes model download and deployment)

## Setup Scripts (000-040)

These scripts handle initial infrastructure setup and are required for both architectures.

### 📦 000: Setup Category

Informational script showing available setup scripts.

```bash
./scripts/000-setup-category.sh
```

### 🔧 010: Setup Build Box

**Purpose**: First-time setup of the build/edge box

**Run on**: Build box or Edge EC2 instance

**What it does**:
1. Installs Python 3.10+, pip, venv
2. Installs AWS CLI
3. Creates Python virtual environment
4. Installs Python dependencies (riva-client, websockets, etc.)
5. Generates self-signed SSL certificates (`/opt/riva/certs/`)
6. Creates project directory structure
7. Creates log directories

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/010-setup-build-box.sh
```

**Expected Output**:
```
✅ System dependencies installed
✅ Python 3.10.12 (OK)
✅ Virtual environment created at /opt/riva/venv
✅ Python dependencies installed
✅ SSL certificates created
✅ Directory structure created
```

**Files Created**:
- `/opt/riva/venv/` - Python virtual environment
- `/opt/riva/certs/server.crt` - SSL certificate
- `/opt/riva/certs/server.key` - SSL private key
- `~/transcription-realtime-whisper/logs/` - Log directory

**Time**: ~5 minutes

### 🚀 020: Deploy GPU Instance

**Purpose**: Create and configure AWS GPU EC2 instance

**Run on**: Build box (with AWS CLI configured)

**What it does**:
1. Launches AWS g4dn.xlarge instance (NVIDIA T4 GPU)
2. Installs NVIDIA drivers (535+)
3. Installs Docker + NVIDIA Docker runtime
4. Configures CUDA toolkit
5. Creates security groups
6. Saves instance details to `.env`

**Prerequisites**:
- AWS CLI configured (`aws configure`)
- EC2 permissions in your AWS account
- `.env` file created (or will be created)

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/020-deploy-gpu-instance.sh
```

**Expected Output**:
```
✅ EC2 instance launched: i-0abc123def456
✅ NVIDIA drivers installed: 535.104.12
✅ Docker installed with GPU support
✅ Instance details saved to .env
```

**Environment Variables Updated**:
- `GPU_INSTANCE_ID` - EC2 instance ID
- `GPU_INSTANCE_IP` - Public IP address
- `RIVA_HOST` - GPU IP for gRPC connection

**Time**: ~10 minutes (includes instance launch and driver installation)

### 🔒 030: Configure GPU Security

**Purpose**: Configure security groups for GPU instance (internal-only access)

**Run on**: Build box

**What it does**:
1. Creates/updates security group for GPU instance
2. Allows SSH (port 22) from build box IP
3. Allows gRPC (port 50051) from build box IP
4. Allows Riva HTTP (port 8000) from build box IP
5. Allows WhisperLive WebSocket (port 9090) from edge IP
6. Blocks all other inbound traffic

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/030-configure-gpu-security.sh
```

**Expected Output**:
```
✅ Security group configured for GPU instance
✅ Allowed build box IP: X.X.X.X
✅ Port 22 (SSH): ✓
✅ Port 50051 (gRPC): ✓
✅ Port 8000 (HTTP): ✓
```

**Security Model**:
- GPU instance is **NOT** publicly accessible
- Only build box and edge can connect
- Follows principle of least privilege

**Time**: ~1 minute

### 🌐 031: Configure Build Box Security

**Purpose**: Configure security groups for build box (client allowlist)

**Run on**: Build box

**What it does**:
1. Creates/updates security group for build box
2. Manages client IP allowlist from `authorized_clients.txt`
3. Opens ports 8443 (WebSocket), 8444 (demo UI)
4. Opens port 22 (SSH) for authorized IPs

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/031-configure-buildbox-security.sh
```

**Client Management**:
```bash
# Edit authorized clients
nano authorized_clients.txt

# Add client IPs (one per line)
203.0.113.45
198.51.100.89

# Re-run script to update security group
./scripts/031-configure-buildbox-security.sh
```

**Time**: ~2 minutes

### 🔐 040: Configure Edge Security

**Purpose**: Configure security groups for edge proxy (WhisperLive)

**Run on**: Build box or Edge EC2

**What it does**:
1. Detects edge public IP automatically
2. Adds security group rule on GPU for port 9090
3. Tests connectivity from edge to GPU
4. Verifies WhisperLive WebSocket access

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/040-configure-edge-security.sh
```

**Expected Output**:
```
✅ Detected edge IP: X.X.X.X
✅ Added security group rule for port 9090
✅ Connectivity test successful
```

**Time**: ~1 minute

## WhisperLive Edge Deployment (300-320)

These scripts deploy the WhisperLive edge proxy architecture for real-time Whisper streaming.

### 🌐 305: Setup WhisperLive Edge

**Purpose**: Deploy Caddy reverse proxy on edge EC2 instance

**Run on**: Edge EC2 instance

**What it does**:
1. Installs Docker and Docker Compose
2. Creates project directory structure
3. Creates `.env-http` configuration
4. Generates `Caddyfile` for reverse proxying
5. Creates `docker-compose.yml` for Caddy
6. Starts Caddy container on ports 80/443
7. Configures WebSocket proxying to GPU

**Prerequisites**:
- Edge EC2 instance (t3.medium or similar)
- SSL certificates at `/opt/riva/certs/` (from script 010)
- Script 010 completed

**Usage**:
```bash
# SSH to edge instance
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@EDGE_IP

# Clone repository and run
cd ~/transcription-realtime-whisper
./scripts/305-setup-whisperlive-edge.sh
```

**Expected Output**:
```
✅ Docker installed
✅ Docker Compose installed
✅ Project directory created
✅ Caddyfile created
✅ Docker Compose configuration created
✅ Caddy container started
✅ WHISPERLIVE EDGE PROXY DEPLOYED

Edge Proxy Details:
  - Location: ~/transcription-realtime-whisper
  - HTTPS URL: https://YOUR_EDGE_IP/
  - WebSocket: wss://YOUR_EDGE_IP/ws
```

**Files Created**:
- `~/transcription-realtime-whisper/.env-http`
- `~/transcription-realtime-whisper/Caddyfile`
- `~/transcription-realtime-whisper/docker-compose.yml`
- `~/transcription-realtime-whisper/site/` (placeholder)

**Ports Opened**:
- `80` - HTTP (redirects to HTTPS)
- `443` - HTTPS (serves static files)
- `443/ws` - WSS (proxies to GPU:9090)

**Time**: ~5 minutes

### ⚙️ 310: Configure WhisperLive GPU

**Purpose**: Install and configure WhisperLive on GPU instance

**Run on**: Build box or Edge (will SSH to GPU)

**What it does**:
1. Clones WhisperLive from Collabora GitHub
2. Installs faster-whisper and dependencies
3. Downloads Whisper models (small.en by default)
4. Creates systemd service (`whisperlive.service`)
5. Starts WhisperLive on port 9090
6. Verifies service is running

**Prerequisites**:
- GPU instance running with NVIDIA drivers
- Script 020 completed
- Python 3.10+ on GPU instance

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/310-configure-whisperlive-gpu.sh
```

**Expected Output**:
```
✅ WhisperLive cloned from GitHub
✅ faster-whisper installed
✅ Whisper model downloaded: small.en
✅ systemd service created
✅ WhisperLive service started
✅ WHISPERLIVE GPU CONFIGURATION COMPLETE

WhisperLive Details:
  - Location: ~/whisperlive/WhisperLive
  - Service: whisperlive.service
  - Port: 9090 (WebSocket)
  - Model: Systran/faster-whisper-small.en
```

**Service Management** (on GPU):
```bash
# Check status
sudo systemctl status whisperlive

# View logs
sudo journalctl -u whisperlive -f

# Restart
sudo systemctl restart whisperlive

# Stop
sudo systemctl stop whisperlive
```

**Models Available**:
- `faster-whisper-tiny.en` - Fastest, lowest accuracy
- `faster-whisper-small.en` - **Default** - Good balance
- `faster-whisper-medium.en` - Better accuracy, slower
- `faster-whisper-large-v2` - Best accuracy, slowest

**Time**: ~10 minutes (includes model download)

### 🧪 315: Test WhisperLive Connection

**Purpose**: End-to-end validation of WhisperLive deployment

**Run on**: Edge EC2 instance

**What it does**:
1. Tests Python dependencies (websockets, etc.)
2. Tests network connectivity (GPU port 9090)
3. Tests WebSocket connection to WhisperLive
4. Sends test audio and verifies transcription
5. Tests browser client accessibility

**Prerequisites**:
- Scripts 305, 310, 040 completed
- WhisperLive service running on GPU

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/315-test-whisperlive-connection.sh
```

**Expected Output**:
```
✅ Python dependencies: OK
✅ Network connectivity: OK (port 9090)
✅ WebSocket connection: OK
✅ Audio transcription: OK
✅ Browser client: OK

Test Results Summary:
  ✓ WhisperLive service is healthy
  ✓ Edge → GPU communication working
  ✓ Browser client accessible at https://YOUR_EDGE_IP/
```

**What's Tested**:
- WebSocket connection establishment
- WhisperLive protocol (config message)
- Audio streaming (Float32 PCM)
- Transcription response
- HTTP/HTTPS access

**Time**: ~1 minute

### 🌐 320: Update Edge Clients

**Purpose**: Deploy browser client files to edge proxy

**Run on**: Edge EC2 instance

**What it does**:
1. Copies `site/index.html` to project directory
2. Copies `site/test-whisper.html` to project directory
3. Copies `test_client.py` for debugging
4. Restarts Caddy to serve new files
5. Updates configuration

**Prerequisites**:
- Script 305 completed (Caddy running)

**Usage**:
```bash
cd ~/transcription-realtime-whisper
./scripts/320-update-edge-clients.sh
```

**Expected Output**:
```
✅ index.html deployed
✅ test-whisper.html deployed
✅ test_client.py deployed
✅ Caddy restarted
✅ BROWSER CLIENTS DEPLOYED

Available URLs:
  - Main UI: https://YOUR_EDGE_IP/
  - Test UI: https://YOUR_EDGE_IP/test-whisper.html
```

**Client Features**:
- Real-time transcription display
- Model selection dropdown
- Language configuration
- Partial vs Final transcript highlighting
- Timestamp display
- Modern responsive UI
- WebSocket status indicator

**Time**: ~1 minute

## Browser Clients

### Main UI (`index.html`)

**Features**:
- Clean, modern interface
- Real-time transcription display
- Model selection (small, medium, large)
- Language selection
- Status indicators
- Transcript history

**Usage**:
1. Open `https://YOUR_EDGE_IP/`
2. Accept SSL certificate warning (self-signed)
3. Select model (default: small.en)
4. Click "Start Recording"
5. Allow microphone access
6. Speak and see real-time transcriptions!

**Transcript Types**:
- **Partial** (gray, italic): Interim results that may change
- **Final** (green border): Completed segments

### Test UI (`test-whisper.html`)

**Features**:
- Minimal debugging interface
- Raw WebSocket message display
- Audio format validation
- Connection diagnostics

**Usage**:
```
https://YOUR_EDGE_IP/test-whisper.html
```

### Python Test Client (`test_client.py`)

**Purpose**: Command-line testing and debugging

**Usage**:
```bash
cd ~/transcription-realtime-whisper
python3 test_client.py
```

## Critical Technical Details

### Audio Format Requirements (CRITICAL!)

**WhisperLive expects Float32 PCM, NOT Int16!**

This is the #1 cause of "no transcriptions" issues.

| Parameter | Value |
|-----------|-------|
| **Sample Rate** | 16,000 Hz |
| **Channels** | 1 (mono) |
| **Format** | **Float32 PCM** |
| **Encoding** | Little-endian |
| **Value Range** | -1.0 to +1.0 |
| **Chunk Size** | 4096 samples |
| **Chunk Bytes** | 16,384 bytes (4096 × 4) |

### Browser Implementation

**✅ CORRECT Implementation**:
```javascript
// Use AudioContext with Float32Array
const audioContext = new AudioContext({ sampleRate: 16000 });
const processor = audioContext.createScriptProcessor(4096, 1, 1);

processor.onaudioprocess = (e) => {
    // getChannelData returns Float32Array
    const audioData = e.inputBuffer.getChannelData(0);

    // Send raw ArrayBuffer (Float32 PCM)
    ws.send(audioData.buffer);
};
```

**❌ WRONG - Do NOT do this**:
```javascript
// Don't convert to Int16
const int16 = new Int16Array(audioData.length);
for (let i = 0; i < audioData.length; i++) {
    int16[i] = Math.max(-32768, Math.min(32767, audioData[i] * 32768));
}
ws.send(int16.buffer);  // ❌ WRONG! WhisperLive won't process this
```

**❌ WRONG - Don't use MediaRecorder**:
```javascript
// MediaRecorder sends compressed audio (WebM/Opus)
const recorder = new MediaRecorder(stream);  // ❌ Wrong for WhisperLive
```

See [FLOAT32_FIX.md](FLOAT32_FIX.md) for complete details.

### WhisperLive WebSocket Protocol

**1. Client → Server (Configuration)**:
```json
{
  "uid": "browser-123456",
  "task": "transcribe",
  "language": "en",
  "model": "Systran/faster-whisper-small.en",
  "use_vad": false
}
```

**2. Server → Client (Ready)**:
```json
{
  "uid": "browser-123456",
  "message": "SERVER_READY",
  "backend": "faster_whisper"
}
```

**3. Client → Server (Audio Data)**:
- Binary frames containing Float32 PCM audio
- 4096 samples per chunk (16,384 bytes)
- Sent continuously while recording

**4. Server → Client (Transcription)**:
```json
{
  "uid": "browser-123456",
  "segments": [
    {
      "start": "0.000",
      "end": "2.816",
      "text": " Hello world",
      "completed": false
    }
  ]
}
```

**Message Flow**:
```
Browser                     Edge (Caddy)              GPU (WhisperLive)
   │                            │                            │
   │──── Config JSON ──────────▶│────────────────────────────▶│
   │                            │                            │
   │◀─── SERVER_READY ──────────│◀────────────────────────────│
   │                            │                            │
   │──── Float32 Audio ────────▶│────────────────────────────▶│
   │──── (streaming) ──────────▶│────────────────────────────▶│
   │                            │                            │
   │◀─── Transcriptions ────────│◀────────────────────────────│
   │◀─── (continuous) ──────────│◀────────────────────────────│
```

## Cost Optimization

### Instance Pricing (us-east-2)

| Component | Instance Type | Running | Stopped |
|-----------|--------------|---------|---------|
| **GPU** | g4dn.xlarge | $0.526/hr | $0.01/hr (EBS) |
| **Edge** | t3.medium | $0.042/hr | $0.01/hr (EBS) |
| **Build Box** | t3.small | $0.021/hr | Optional |

### Cost Savings Strategy

**Shutdown GPU overnight** (saves ~$12/day):

```bash
# Stop GPU instance
cd ~/transcription-realtime-whisper
./scripts/210-shutdown-gpu.sh
```

**Startup in the morning**:

```bash
# Start GPU and restore services
cd ~/transcription-realtime-whisper
./scripts/220-startup-restore.sh
```

**Keep Edge running 24/7**:
- Edge proxy can stay running (cheap at $0.042/hr)
- Only GPU needs to be shut down
- Browser clients remain accessible (will show "connecting..." when GPU is down)

### Monthly Cost Estimates

**Scenario 1: GPU running 24/7**
- GPU: $0.526/hr × 730 hrs = **$384/month**
- Edge: $0.042/hr × 730 hrs = **$31/month**
- **Total: $415/month**

**Scenario 2: GPU running 8 hours/day**
- GPU: $0.526/hr × 240 hrs = **$126/month**
- Edge: $0.042/hr × 730 hrs = **$31/month**
- **Total: $157/month**

**Scenario 3: GPU running weekdays only (8hrs/day)**
- GPU: $0.526/hr × 160 hrs = **$84/month**
- Edge: $0.042/hr × 730 hrs = **$31/month**
- **Total: $115/month**

## Troubleshooting

### No Transcriptions Appearing

**Most common cause**: Wrong audio format!

**Fix**:
1. Open browser console (F12)
2. Check audio format:
   ```javascript
   console.log(audioContext.sampleRate);  // Should be 16000
   console.log(audioData.constructor.name);  // Should be "Float32Array"
   ```
3. Verify you're NOT converting to Int16
4. Verify you're NOT using MediaRecorder

See [FLOAT32_FIX.md](FLOAT32_FIX.md) for details.

### Connection Refused

**Check WhisperLive service**:
```bash
ssh ubuntu@GPU_IP sudo systemctl status whisperlive
```

**Check security groups**:
```bash
# From edge instance
nc -zv GPU_IP 9090
```

**Restart service**:
```bash
ssh ubuntu@GPU_IP sudo systemctl restart whisperlive
```

### SSL Certificate Errors

**Verify certificates exist**:
```bash
ls -lh /opt/riva/certs/
# Should show server.crt and server.key
```

**Recreate if missing**:
```bash
sudo mkdir -p /opt/riva/certs
sudo openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /opt/riva/certs/server.key \
  -out /opt/riva/certs/server.crt \
  -days 365 \
  -subj "/C=US/ST=State/L=City/O=Org/CN=localhost"
```

### WebSocket 404 Errors

**Check Caddyfile**:
```bash
cat ~/transcription-realtime-whisper/Caddyfile
# Should have "handle /ws" block
```

**Restart Caddy**:
```bash
cd ~/transcription-realtime-whisper
docker compose restart caddy
```

### GPU Instance Not Starting

**Check instance state**:
```bash
aws ec2 describe-instances --instance-ids $GPU_INSTANCE_ID
```

**Start manually**:
```bash
./scripts/730-start-gpu-instance.sh
```

### Edge Proxy Not Responding

**Check Caddy logs**:
```bash
cd ~/transcription-realtime-whisper
docker compose logs -f
```

**Restart Caddy**:
```bash
docker compose restart
```

## Documentation

### Quick Start Guides
- **[README_300_SERIES.md](README_300_SERIES.md)** - WhisperLive quick start
- **[DEPLOYMENT_GUIDE_300_SERIES.md](DEPLOYMENT_GUIDE_300_SERIES.md)** - Detailed WhisperLive guide
- **[COMPLETE_DEPLOYMENT_GUIDE.md](COMPLETE_DEPLOYMENT_GUIDE.md)** - Full deployment (000-320)

### Technical Deep-Dives
- **[FLOAT32_FIX.md](FLOAT32_FIX.md)** - Audio format requirements (critical!)
- **[EDGE-DEPLOYMENT.md](EDGE-DEPLOYMENT.md)** - Edge architecture details
- **[CLAUDE.md](CLAUDE.md)** - Project overview for AI assistants

### NVIDIA Riva Documentation
- **[STREAMING_ASR_BEST_PRACTICES.md](STREAMING_ASR_BEST_PRACTICES.md)** - Riva best practices
- **[docs/CONFORMER_CTC_STREAMING_GUIDE.md](docs/CONFORMER_CTC_STREAMING_GUIDE.md)** - Conformer-CTC details

## Project Structure

```
transcription-realtime-whisper/
├── README.md                          # This file
├── .env                               # Environment configuration (gitignored)
├── .gitignore                         # Git ignore rules
│
├── scripts/                           # Deployment automation
│   ├── 000-setup-category.sh          # Setup scripts overview
│   ├── 010-setup-build-box.sh         # Build box prerequisites
│   ├── 020-deploy-gpu-instance.sh     # Deploy GPU EC2 instance
│   ├── 030-configure-gpu-security.sh  # GPU security groups (internal)
│   ├── 031-configure-buildbox-security.sh  # Build box security (client allowlist)
│   ├── 040-configure-edge-security.sh # Edge security groups
│   │
│   ├── 100-165/                       # NVIDIA Riva deployment scripts
│   ├── 200-220/                       # Operations (shutdown/startup)
│   │
│   ├── 300-whisperlive-edge-category.sh  # WhisperLive scripts overview
│   ├── 305-setup-whisperlive-edge.sh  # Deploy Caddy edge proxy
│   ├── 310-configure-whisperlive-gpu.sh  # Install WhisperLive on GPU
│   ├── 315-test-whisperlive-connection.sh  # End-to-end validation
│   ├── 320-update-edge-clients.sh     # Deploy browser clients
│   │
│   ├── riva-common-functions.sh       # Shared bash utilities
│   └── riva-common-library.sh         # Extended utilities
│
├── site/                              # Browser client files
│   ├── index.html                     # Main WhisperLive UI
│   └── test-whisper.html              # Test/debug UI
│
├── src/                               # Source code
│   └── asr/                          # ASR modules
│       ├── riva_client.py             # RIVA gRPC client
│       ├── riva_websocket_bridge.py   # WebSocket ↔ gRPC bridge
│       ├── transcript_accumulator.py  # Transcript processing
│       └── nim_http_client.py         # NIM HTTP client
│
├── audio-api/                         # S3 audio storage API
├── docs/                              # Additional documentation
├── tests/                             # Unit tests
└── logs/                              # Deployment logs
```

## Script Categories

### Setup (000-040)
Initial infrastructure and security setup.

### Deployment (100-165)
NVIDIA Riva model deployment and services.

### Operations (200-220)
Daily operations (shutdown/startup GPU).

### WhisperLive Edge (300-320)
WhisperLive edge proxy deployment.

### Management (700-999)
Advanced GPU instance management.

## Support

### GitHub Issues
https://github.com/davidbmar/transcription-realtime-whisper/issues

### External Resources
- **NVIDIA Riva Docs**: https://docs.nvidia.com/deeplearning/riva/user-guide/
- **WhisperLive GitHub**: https://github.com/collabora/WhisperLive
- **faster-whisper**: https://github.com/guillaumekln/faster-whisper

## License

MIT License - See [LICENSE](LICENSE) file

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test thoroughly
4. Submit a pull request

## Credits

Built with:
- **NVIDIA Riva 2.19** - Enterprise speech AI
- **Collabora WhisperLive** - Open-source Whisper streaming
- **OpenAI Whisper** - Foundation models
- **faster-whisper** - CUDA-accelerated inference

---

**Ready to transcribe in real-time?** Start with [Quick Start](#quick-start) above! 🎤
