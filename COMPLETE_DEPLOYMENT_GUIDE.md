# Complete WhisperLive Edge Proxy Deployment Guide

**From zero to real-time speech recognition in your browser**

This guide covers the complete deployment using scripts 005-320, from initial setup through WhisperLive edge proxy deployment.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Phase 1: Initial Setup (005-040)](#phase-1-initial-setup-005-040)
5. [Phase 2: WhisperLive Edge (300-320)](#phase-2-whisperlive-edge-300-320)
6. [Testing and Validation](#testing-and-validation)
7. [Daily Operations](#daily-operations)
8. [Troubleshooting](#troubleshooting)

## Overview

This deployment creates a production-ready real-time speech recognition system using:

- **GPU Worker**: NVIDIA Riva OR WhisperLive faster-whisper
- **Edge Proxy**: Caddy reverse proxy with SSL termination
- **Browser Client**: Real-time transcription UI

You can deploy either:
1. **NVIDIA Riva Conformer-CTC** (scripts 005-165) - Enterprise-grade ASR
2. **WhisperLive faster-whisper** (scripts 300-320) - Open-source Whisper streaming

Or both! They can coexist on the same GPU instance.

## Architecture

### WhisperLive Edge Proxy (300 Series)

```
┌─────────────┐     HTTPS/WSS      ┌──────────────┐      WS        ┌─────────────┐
│   Browser   │──────:443──────────▶│  Edge EC2    │────:9090───────▶│  GPU EC2    │
│  (Client)   │                     │   (Caddy)    │                 │ (WhisperLive)│
└─────────────┘                     └──────────────┘                 └─────────────┘
     │                                     │                                 │
     │ Mic → Float32 PCM                  │ SSL Termination                 │
     │ @ 16kHz mono                        │ WebSocket Proxy                 │
     │                                     │                                 │
     └─────────────────────────────────────┴─────────────────────────────────┘
              Transcriptions flow back as JSON segments
```

### NVIDIA Riva Architecture (100-165 Series)

```
┌─────────────┐     WSS/HTTPS      ┌──────────────┐      gRPC      ┌─────────────┐
│   Browser   │──────:8443─────────▶│  Build Box   │────:50051──────▶│  GPU EC2    │
│  (Client)   │      :8444          │  (WS Bridge) │                 │   (Riva)    │
└─────────────┘                     └──────────────┘                 └─────────────┘
```

## Prerequisites

### AWS Resources

- **AWS Account** with EC2 permissions
- **SSH Key Pair** (default: dbm-sep23-2025)
- **Security Groups** with appropriate rules
- **VPC** with internet gateway

### Local Machine

- **AWS CLI** configured with credentials
- **SSH client** for connecting to instances
- **Modern browser** (Chrome, Firefox, Edge)

### Knowledge

- Basic Linux command line
- SSH and networking concepts
- AWS EC2 basics

## Phase 1: Initial Setup (005-040)

### Script 005: Configuration Setup

**Purpose**: Create and configure `.env` file with all settings

**Run on**: Build box (local development machine or EC2)

```bash
cd ~/event-b/whisper-live-test
./scripts/005-setup-configuration.sh
```

**What it configures**:
- AWS region and account ID
- GPU instance type (g4dn.xlarge)
- SSH key name
- NVIDIA NGC API key
- S3 bucket paths
- Port numbers
- SSL settings

**Output**: `.env` file with all configuration

**Important**: Get your NGC API key from https://ngc.nvidia.com/

---

### Script 010: Build Box Setup

**Purpose**: Install prerequisites on build box

**Run on**: Build box

```bash
cd ~/event-b/whisper-live-test
./scripts/010-setup-build-box.sh
```

**What it installs**:
- Python 3.10+ and pip
- AWS CLI
- Python virtual environment
- Python dependencies (riva-client, websockets, etc.)
- SSL certificates (self-signed)
- Project directory structure

**Output**:
- `/opt/riva/nvidia-riva-conformer-streaming/` (project location)
- `/opt/riva/certs/` (SSL certificates)
- Python venv with all dependencies

**Time**: ~5 minutes

---

### Script 020: Deploy GPU Instance

**Purpose**: Create and configure GPU EC2 instance

**Run on**: Build box

```bash
cd ~/event-b/whisper-live-test
./scripts/020-deploy-gpu-instance.sh
```

**What it does**:
- Launches g4dn.xlarge instance
- Configures NVIDIA drivers
- Installs Docker with GPU support
- Sets up security groups
- Updates `.env` with instance details

**Output**: Running GPU instance with NVIDIA drivers ready

**Time**: ~10 minutes

**Cost**: ~$0.526/hour (GPU instance)

---

### Script 030: Configure GPU Security

**Purpose**: Set up security groups for GPU instance

**Run on**: Build box

```bash
cd ~/event-b/whisper-live-test
./scripts/030-configure-gpu-security.sh
```

**What it does**:
- Creates/updates security groups
- Allows SSH from build box
- Allows gRPC (50051) from build box
- Allows HTTP (8000) from build box
- **Important**: GPU is NOT publicly accessible

**Security Model**: GPU only accepts connections from build box IP

---

### Script 031: Configure Build Box Security

**Purpose**: Set up security groups for build box (for RIVA)

**Run on**: Build box

```bash
cd ~/event-b/whisper-live-test
./scripts/031-configure-buildbox-security.sh
```

**What it does**:
- Creates/updates security groups
- Allows SSH from authorized IPs
- Allows WebSocket (8443) from client IPs
- Allows HTTPS demo (8444) from client IPs
- Manages client IP allowlist

**Security Model**: Build box accepts connections from specific client IPs only

---

### Script 040: Configure Edge Security

**Purpose**: Allow edge machine to access GPU WhisperLive

**Run on**: Edge box or build box

```bash
cd ~/event-b/whisper-live-test
./scripts/040-configure-edge-security.sh
```

**What it does**:
- Detects edge public IP
- Adds security group rule for port 9090
- Tests connectivity to GPU
- Validates WhisperLive is accessible

**When to run**: After GPU is set up, before deploying edge proxy

---

## Phase 2: WhisperLive Edge (300-320)

### Overview

The 300 series scripts deploy WhisperLive with an edge proxy architecture:
- **Edge EC2**: Public-facing Caddy reverse proxy
- **GPU EC2**: Private WhisperLive server
- **Browser**: Connects to edge, edge proxies to GPU

This is more secure and flexible than exposing GPU directly.

---

### Script 305: Setup WhisperLive Edge

**Purpose**: Deploy Caddy reverse proxy on edge EC2

**Run on**: Edge EC2 instance

```bash
cd ~/event-b/whisper-live-test
./scripts/305-setup-whisperlive-edge.sh
```

**What it does**:
1. Installs Docker and Docker Compose
2. Creates project directory (`~/event-b/whisper-live-test`)
3. Creates `.env-http` configuration
4. Creates Caddyfile for WebSocket proxying
5. Creates docker-compose.yml
6. Starts Caddy container

**Requirements**:
- SSL certificates at `/opt/riva/certs/` (copy from build box if needed)
- GPU instance IP (from `.env` or manual entry)

**Output**:
- Running Caddy container on ports 80/443
- HTTPS endpoint: `https://EDGE_IP/`
- WebSocket endpoint: `wss://EDGE_IP/ws`

**Time**: ~5 minutes

---

### Script 310: Configure WhisperLive GPU

**Purpose**: Install and configure WhisperLive on GPU instance

**Run on**: Build box or edge box (will SSH to GPU)

```bash
cd ~/event-b/whisper-live-test
./scripts/310-configure-whisperlive-gpu.sh
```

**What it does**:
1. Clones WhisperLive from Collabora GitHub
2. Installs faster-whisper and dependencies
3. Downloads Whisper models (small.en)
4. Creates systemd service
5. Starts WhisperLive on port 9090

**On GPU**:
- Location: `~/whisperlive/WhisperLive`
- Service: `whisperlive.service`
- Port: 9090 (WebSocket)
- Backend: faster_whisper

**Time**: ~10 minutes (includes model download)

**GPU Commands**:
```bash
# Check status
sudo systemctl status whisperlive

# View logs
sudo journalctl -u whisperlive -f

# Restart
sudo systemctl restart whisperlive
```

---

### Script 320: Update Edge Clients

**Purpose**: Deploy browser client files to edge proxy

**Run on**: Edge EC2 instance

```bash
cd ~/event-b/whisper-live-test
./scripts/320-update-edge-clients.sh
```

**What it deploys**:
- `index.html` - Main WhisperLive UI (modern, styled)
- `test-whisper.html` - Simple test client
- `test_client.py` - Python debugging client

**What it does**:
1. Copies client files to `~/event-b/whisper-live-test/site/`
2. Restarts Caddy to pick up changes
3. Verifies deployment

**URLs**:
- Main UI: `https://EDGE_IP/`
- Test UI: `https://EDGE_IP/test-whisper.html`
- Health: `https://EDGE_IP/healthz`

**Time**: ~1 minute

---

### Script 315: Test WhisperLive Connection

**Purpose**: Validate end-to-end WhisperLive connectivity

**Run on**: Edge EC2 instance

```bash
cd ~/event-b/whisper-live-test
./scripts/315-test-whisperlive-connection.sh
```

**What it tests**:
1. Python dependencies
2. Network connectivity to GPU
3. WebSocket connection
4. Audio transcription (with test file)
5. Browser client accessibility

**Expected output**:
```
✅ WhisperLive Connection Tests Complete

Test Results Summary:
  ✓ Python dependencies: OK
  ✓ Network connectivity: OK
  ✓ WebSocket connection: OK
  ✓ Audio transcription: OK
  ✓ Browser client: OK
```

**Time**: ~1 minute

---

## Testing and Validation

### Browser Testing

1. **Open browser**:
   ```
   https://YOUR_EDGE_IP/
   ```

2. **Accept SSL certificate warning**
   - Self-signed certificate, so browser will warn
   - Click "Advanced" → "Proceed to site"

3. **Configure (optional)**:
   - Select model: small.en (fast), medium.en, large-v2, large-v3
   - Set language: en, es, fr, etc.

4. **Start recording**:
   - Click "Start Recording"
   - Allow microphone access when prompted

5. **Speak clearly**:
   - Watch transcriptions appear in real-time
   - Partial results shown in gray (interim)
   - Final results shown in green (completed)

### Python Testing

Use the test client for debugging:

```bash
cd ~/event-b/whisper-live-test
python3 test_client.py
```

Output shows:
- WebSocket connection status
- SERVER_READY message
- Transcription segments with timestamps

### Verification Checklist

- [ ] Edge Caddy container running (`docker compose ps`)
- [ ] GPU WhisperLive service running (`sudo systemctl status whisperlive`)
- [ ] Security groups allow edge→GPU on port 9090
- [ ] Security groups allow client→edge on ports 80/443
- [ ] SSL certificates present at `/opt/riva/certs/`
- [ ] Browser can access `https://EDGE_IP/`
- [ ] Transcriptions appear when speaking

---

## Daily Operations

### Starting Up

If GPU was shut down to save costs:

```bash
# From build box
cd /opt/riva/nvidia-riva-conformer-streaming
./scripts/220-startup-restore.sh
```

This starts GPU instance and restores all services.

**Edge proxy can stay running** (cheap t3.medium instance).

---

### Shutting Down

To save costs when not in use:

```bash
# From build box
cd /opt/riva/nvidia-riva-conformer-streaming
./scripts/210-shutdown-gpu.sh
```

**Shutdown only GPU** (~$0.526/hr saved). Edge can stay up (~$0.04/hr).

---

### Monitoring

**Edge Proxy (Caddy)**:
```bash
# On edge box
cd ~/event-b/whisper-live-test

# View logs
docker compose logs -f

# Status
docker compose ps

# Restart
docker compose restart
```

**GPU WhisperLive**:
```bash
# SSH to GPU
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@GPU_IP

# View logs
sudo journalctl -u whisperlive -f

# Status
sudo systemctl status whisperlive

# Restart
sudo systemctl restart whisperlive
```

---

### Updating Clients

To deploy updated browser client code:

```bash
# On edge box
cd ~/event-b/whisper-live-test

# Edit files in site/
vim site/index.html

# Deploy changes
./scripts/320-update-edge-clients.sh
```

Caddy will automatically pick up changes.

---

## Troubleshooting

### No Transcriptions

**Most common**: Wrong audio format!

WhisperLive expects **Float32 PCM @ 16kHz**, NOT Int16 or WebM.

**Fix**:
1. Check browser console for errors
2. Verify `audioContext.sampleRate === 16000`
3. Verify `audioData.constructor.name === "Float32Array"`
4. See `FLOAT32_FIX.md` for details

---

### Connection Refused

**Cause**: Network or security group issue

**Fix**:
1. Check WhisperLive running:
   ```bash
   ssh ubuntu@GPU_IP sudo systemctl status whisperlive
   ```

2. Check security groups:
   - Edge IP allowed on GPU port 9090?
   - Your IP allowed on edge ports 80/443?

3. Test connectivity:
   ```bash
   nc -zv GPU_IP 9090
   ```

4. Re-run security script:
   ```bash
   ./scripts/040-configure-edge-security.sh
   ```

---

### SSL Certificate Errors

**Cause**: Missing or invalid certificates

**Fix**:
1. Check certificates exist:
   ```bash
   ls -lh /opt/riva/certs/
   ```

2. Recreate if needed:
   ```bash
   openssl req -x509 -newkey rsa:4096 -nodes \
     -keyout /opt/riva/certs/server.key \
     -out /opt/riva/certs/server.crt \
     -days 365 \
     -subj "/C=US/ST=State/L=City/O=Org/CN=localhost"
   ```

3. Restart Caddy:
   ```bash
   docker compose restart caddy
   ```

---

### WebSocket 404

**Cause**: Caddyfile misconfiguration

**Fix**:
1. Check Caddyfile has `handle /ws` block:
   ```bash
   cat ~/event-b/whisper-live-test/Caddyfile
   ```

2. Should contain:
   ```caddy
   handle /ws {
       reverse_proxy {$GPU_HOST}:{$GPU_PORT}
   }
   ```

3. Restart if changed:
   ```bash
   docker compose restart caddy
   ```

---

### Buffer Size Errors

**Cause**: Wrong audio format (Int16 instead of Float32)

**Fix**: Update browser clients with script 320:
```bash
./scripts/320-update-edge-clients.sh
```

---

## Cost Summary

### Running Costs

| Component | Instance Type | Cost/Hour | Notes |
|-----------|--------------|-----------|-------|
| GPU | g4dn.xlarge | $0.526 | Shut down when not in use |
| Edge | t3.medium | $0.042 | Can run 24/7 cheaply |
| Build Box | t3.small | $0.021 | Optional, can use laptop |

### Cost Optimization

**Recommended**:
- Shut down GPU nightly (saves ~$12/day)
- Keep edge running 24/7 (only $1/day)
- Use build box only when deploying

**Scripts**:
- Shutdown: `210-shutdown-gpu.sh`
- Startup: `220-startup-restore.sh`

---

## Complete Script Reference

### Setup Phase (005-040)

| Script | Purpose | Run On | Time |
|--------|---------|--------|------|
| 005 | Configuration setup | Build box | 5 min |
| 010 | Build box prerequisites | Build box | 5 min |
| 020 | Deploy GPU instance | Build box | 10 min |
| 030 | GPU security groups | Build box | 1 min |
| 031 | Build box security groups | Build box | 2 min |
| 040 | Edge security groups | Edge/Build | 1 min |

### WhisperLive Phase (300-320)

| Script | Purpose | Run On | Time |
|--------|---------|--------|------|
| 305 | Setup edge proxy | Edge box | 5 min |
| 310 | Configure WhisperLive GPU | Build/Edge | 10 min |
| 320 | Deploy browser clients | Edge box | 1 min |
| 315 | Test end-to-end | Edge box | 1 min |

### Operations (200s)

| Script | Purpose | Run On | Notes |
|--------|---------|--------|-------|
| 210 | Shutdown GPU | Build box | Save costs |
| 220 | Startup GPU | Build box | Restore from shutdown |

---

## Quick Start Commands

**Complete deployment from scratch**:

```bash
# Phase 1: Setup (on build box)
./scripts/005-setup-configuration.sh
./scripts/010-setup-build-box.sh
./scripts/020-deploy-gpu-instance.sh
./scripts/030-configure-gpu-security.sh
./scripts/031-configure-buildbox-security.sh

# Phase 2: WhisperLive (on edge box)
./scripts/305-setup-whisperlive-edge.sh
./scripts/310-configure-whisperlive-gpu.sh
./scripts/040-configure-edge-security.sh
./scripts/320-update-edge-clients.sh
./scripts/315-test-whisperlive-connection.sh

# Open browser
open https://YOUR_EDGE_IP/
```

**Total time**: ~40 minutes for complete setup

---

## Additional Documentation

- **DEPLOYMENT_GUIDE_300_SERIES.md** - Detailed 300 series guide
- **FLOAT32_FIX.md** - Audio format deep dive
- **EDGE-DEPLOYMENT.md** - Edge architecture details
- **CHATGPT_PROMPT.md** - Debugging guide
- **CLAUDE.md** - Project overview for Claude Code

---

## Support and Issues

**Logs locations**:
- Build box: `~/event-b/whisper-live-test/logs/`
- Edge Caddy: `docker compose logs`
- GPU WhisperLive: `sudo journalctl -u whisperlive`

**Common fixes**:
1. Check audio format (Float32!)
2. Verify security groups
3. Check service status
4. Review logs
5. Restart services

**When in doubt**:
```bash
# Restart everything
docker compose restart  # On edge
sudo systemctl restart whisperlive  # On GPU
```

---

**Success looks like**:
1. Browser opens at `https://EDGE_IP/`
2. Click "Start Recording"
3. Speak clearly
4. Transcriptions appear in real-time
5. Partial results update live
6. Final results shown with green border

**Enjoy real-time speech recognition!** 🎤✨
