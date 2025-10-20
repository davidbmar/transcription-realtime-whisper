# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**WhisperLive Real-Time Transcription** - Production-ready real-time speech transcription system using OpenAI Whisper models via WhisperLive on AWS GPU infrastructure.

### Architecture

The system consists of two main components:
1. **GPU Worker** (AWS g4dn.xlarge) - Runs WhisperLive server with Whisper models
2. **Build Box** - Manages deployment and optional edge proxy (Caddy)

```
Client --> WhisperLive Server (GPU Worker)
           :9090 (WebSocket)
```

## Key Commands

### Daily Operations (Run from Build Box)
```bash
# Start GPU and restore WhisperLive
./scripts/220-startup-restore.sh        # Complete restoration (3-5 min)

# Stop GPU to save costs
./scripts/200-shutdown-gpu.sh           # ~$0.526/hour savings
```

### GPU Instance Management
```bash
# Advanced controls
./scripts/730-start-gpu-instance.sh     # Start GPU with health checks
./scripts/740-stop-gpu-instance.sh      # Stop GPU
./scripts/750-status-gpu-instance.sh    # Check GPU status
```

### WhisperLive Management
```bash
# Check WhisperLive service (on GPU worker)
ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$GPU_INSTANCE_IP 'systemctl status whisperlive'

# View logs
ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u whisperlive -f'

# Configure WhisperLive on GPU
./scripts/310-configure-whisperlive-gpu.sh
```

### Security Configuration
```bash
# Configure GPU security (internal-only access from build box)
./scripts/030-configure-gpu-security.sh

# Manage client access to build box
./scripts/031-configure-buildbox-security.sh
```

**Security Model:**
- **GPU Worker**: Internal-only - accepts connections ONLY from build box (ports 22, 9090)
- **Build Box**: Can optionally expose WhisperLive via Caddy reverse proxy
- **Client IPs**: Stored in `authorized_clients.txt`, managed via script 031

## Architecture Details

### Environment Variables

All configuration is in `.env` file (copied from `.env.example`):

**GPU Instance Config:**
- `GPU_INSTANCE_ID` - **Source of truth** (instance ID, never changes)
- `GPU_INSTANCE_IP` - Auto-updated by scripts when GPU starts
- `GPU_HOST` - Same as GPU_INSTANCE_IP, used by WhisperLive clients
- `SSH_KEY_NAME` - SSH key name (e.g., `dbm-oct18-2025`)

**AWS Config:**
- `AWS_REGION` - Default: `us-east-2`

**Optional:**
- `BUILDBOX_PUBLIC_IP` - Build box public IP (for demos)

### Script 220: Startup and Restore

The primary daily operation script that handles everything:

**What it does:**
1. Starts GPU EC2 instance (uses `GPU_INSTANCE_ID` from `.env`)
2. Waits for instance to be ready
3. Queries AWS for current IP (IP changes on every stop/start)
4. If IP changed:
   - Updates `.env` (GPU_INSTANCE_IP, GPU_HOST)
   - Updates `.env-http` in multiple locations (DOMAIN, GPU_HOST)
   - Updates AWS security groups
   - Recreates Docker containers (Caddy) to load new IP
5. Verifies SSH connectivity
6. Checks WhisperLive service status
7. Deploys WhisperLive if needed (calls `310-configure-whisperlive-gpu.sh`)
8. Ensures WhisperLive service is running

**Time:** 3-5 minutes (2min startup + 1-3min deployment if needed)

**Instance ID as Source of Truth:**
- The `.env` file stores `GPU_INSTANCE_ID` (never changes)
- The IP is **derived** from instance ID at runtime
- IP is cached in `.env` but always refreshed on startup

### WhisperLive Deployment (Script 310)

Installs and configures WhisperLive on the GPU worker:
1. Install system dependencies (Python 3.9, ffmpeg, portaudio)
2. Clone WhisperLive from GitHub (Collabora fork)
3. Create Python 3.9 virtual environment
4. Install faster-whisper and dependencies
5. Download Whisper models
6. Create systemd service for WhisperLive
7. Start WhisperLive server on port 9090
8. Verify health endpoint responds

### Cost Optimization Pattern

The shutdown/startup scripts enable overnight cost savings:
- `200-shutdown-gpu.sh` - Stop GPU instance (preserves EBS volume)
- `220-startup-restore.sh` - Restore full working state in one command

**Workflow:**
```bash
# End of day
./scripts/200-shutdown-gpu.sh

# Next morning
./scripts/220-startup-restore.sh  # Everything just works!
```

## Common Patterns

### SSH to GPU Worker

All scripts use SSH keys from `.env`:
```bash
SSH_KEY_NAME=dbm-oct18-2025  # In .env
SSH_KEY="${SSH_KEY:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"
ssh -i "$SSH_KEY" ubuntu@"$GPU_INSTANCE_IP" '<commands>'
```

### Script Structure

Deployment scripts follow this pattern:
1. Source `riva-common-functions.sh` (generic bash utilities, not RIVA-specific)
2. Load environment with `load_environment`
3. Use logging functions: `log_info`, `log_success`, `log_error`
4. Execute remote commands via SSH heredoc

### Environment Updates

Scripts auto-update `.env` when IP changes:
```bash
sed -i "s/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=$CURRENT_IP/" .env
sed -i "s/^GPU_HOST=.*/GPU_HOST=$CURRENT_IP/" .env
```

## Troubleshooting

### IP Changes After GPU Restart

`220-startup-restore.sh` automatically:
1. Detects IP changes (AWS assigns new IP on every start)
2. Updates `.env` files in multiple locations
3. Updates security groups to allow new IP
4. Recreates Caddy container with new IP
5. Verifies connectivity

### WhisperLive Not Responding

1. Check service status:
   ```bash
   ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$GPU_INSTANCE_IP 'systemctl status whisperlive'
   ```

2. Check logs:
   ```bash
   ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u whisperlive -f'
   ```

3. Verify health endpoint:
   ```bash
   ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$GPU_INSTANCE_IP 'curl http://localhost:9090/health'
   ```

4. Restart service:
   ```bash
   ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$GPU_INSTANCE_IP 'sudo systemctl restart whisperlive'
   ```

### SSH Connection Failures

Check these in order:
1. **SSH key path**: Verify `SSH_KEY_NAME` in `.env` matches actual key file
2. **Security group**: Run `./scripts/030-configure-gpu-security.sh` to update
3. **Instance state**: Run `./scripts/750-status-gpu-instance.sh` to check
4. **IP address**: Verify `GPU_INSTANCE_IP` in `.env` matches actual IP from AWS console

## Important Notes

- All scripts expect to run from repository root
- GPU instance must have NVIDIA drivers for Whisper model acceleration
- WhisperLive systemd service auto-starts on GPU reboot
- **Instance ID is source of truth** - IP is derived at runtime
- RIVA-related scripts (100-165) have been archived - this repo is WhisperLive-only
