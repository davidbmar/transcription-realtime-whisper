# Edge Proxy Setup Guide

## Overview

The edge proxy uses **Caddy** as a reverse proxy to route traffic from the internet to your GPU instances running WhisperLive or RIVA ASR services.

```
Internet → Edge Box (Caddy) → GPU Instances (WhisperLive/RIVA)
```

**Key Features:**
- ✅ HTTPS with self-signed certificates
- ✅ WebSocket support for real-time audio streaming
- ✅ Can route to multiple GPU backends via path-based routing
- ✅ Runs in Docker container for easy management
- ✅ Automatic HTTP → HTTPS redirect

## Architecture

### Single GPU (Default)

```
Internet
    ↓
Edge Box (Public IP: 3.16.124.227)
    ↓
Caddy Container (whisperlive-edge)
├── Port 80 → Redirects to HTTPS
├── Port 443 → HTTPS/WSS
│
└── Routes:
    ├── /ws → GPU (52.15.199.98:9090)
    └── /healthz → Health check
```

### Multi-GPU (After Configuration)

```
Internet
    ↓
Edge Box (Public IP: 3.16.124.227)
    ↓
Caddy Container (whisperlive-edge)
├── Port 443 (HTTPS/WSS)
│
└── Routes:
    ├── /gpu1/ws → GPU 1 (52.15.199.98:9090) - RIVA Conformer
    ├── /gpu2/ws → GPU 2 (10.0.0.5:9090) - WhisperLive
    ├── /gpu3/ws → GPU 3 (10.0.0.10:9090) - Parakeet
    └── /healthz → Health check
```

## Quick Start

### Prerequisites

1. **Edge EC2 instance** running Ubuntu
2. **SSL certificates** at `/opt/riva/certs/` (created by script 010)
3. **GPU instance(s)** running WhisperLive or RIVA
4. **Network access** from edge box to GPU instances (port 9090)

### Step 1: Initial Setup

Run on the **edge box**:

```bash
# Initial setup with first GPU
./scripts/305-setup-whisperlive-edge.sh

# Script will prompt for:
#   - GPU IP address (private IP of your GPU instance)
#   - Email (for SSL certificates)

# Creates:
#   - Container: whisperlive-edge
#   - Config directory: ~/event-b/whisper-live-test/
#   - Default route: /ws → GPU
```

### Step 2: Verify Setup

```bash
# Get your edge box public IP
curl -s ifconfig.me

# Test health endpoint
curl -k https://$(curl -s ifconfig.me)/healthz
# Should return: OK

# Test from browser (replace with your edge IP)
https://3.16.124.227/
```

### Step 3: Configure Security

```bash
# Allow specific client IPs to access edge box
./scripts/031-configure-edge-box-security.sh

# Ensure GPU allows edge box IP on port 9090
./scripts/030-configure-gpu-security.sh
```

## Multi-GPU Configuration

### Adding Multiple GPUs

To route traffic to multiple GPU backends, edit the Caddyfile manually:

```bash
# 1. Edit Caddyfile
nano ~/event-b/whisper-live-test/Caddyfile

# 2. Add GPU routes (see template below)

# 3. Restart Caddy
cd ~/event-b/whisper-live-test
docker compose restart
```

### Multi-GPU Caddyfile Template

Replace the default Caddyfile content with:

```caddy
https:// {
    tls /certs/server.crt /certs/server.key

    # GPU 1 - RIVA Conformer-CTC Streaming
    handle /gpu1/* {
        reverse_proxy 52.15.199.98:9090
    }

    # GPU 2 - WhisperLive Faster-Whisper
    handle /gpu2/* {
        reverse_proxy 10.0.0.5:9090
    }

    # GPU 3 - NVIDIA Parakeet RNNT
    handle /gpu3/* {
        reverse_proxy 10.0.0.10:9090
    }

    # GPU 4 - Add your fourth GPU here
    # handle /gpu4/* {
    #     reverse_proxy YOUR_GPU_IP:9090
    # }

    # Health check endpoint
    handle /healthz {
        respond "OK" 200
    }

    # Default route - Dashboard
    handle {
        root * /srv
        file_server browse
    }

    # Logging
    log {
        output stdout
        format console
    }
}

# HTTP redirect to HTTPS
http:// {
    redir https://{host}{uri} permanent
}
```

### Restart to Apply Changes

```bash
cd ~/event-b/whisper-live-test
docker compose restart

# Verify all GPUs are accessible
curl -k https://$(curl -s ifconfig.me)/gpu1/healthz
curl -k https://$(curl -s ifconfig.me)/gpu2/healthz
curl -k https://$(curl -s ifconfig.me)/gpu3/healthz
```

## Client Configuration

### Browser WebSocket Client

Update your client code to target the appropriate GPU:

#### Single GPU (Default)
```javascript
const edgeIP = '3.16.124.227';
const ws = new WebSocket(`wss://${edgeIP}/ws`);
```

#### Multi-GPU with Selection
```html
<!-- GPU Selector -->
<select id="gpu-selector">
  <option value="gpu1">GPU 1 - RIVA Conformer (Fastest)</option>
  <option value="gpu2">GPU 2 - WhisperLive (Accurate)</option>
  <option value="gpu3">GPU 3 - Parakeet (Experimental)</option>
</select>

<script>
// Get selected GPU
const gpuId = document.getElementById('gpu-selector').value;
const edgeIP = '3.16.124.227';

// Connect to selected GPU via edge proxy
const ws = new WebSocket(`wss://${edgeIP}/${gpuId}/ws`);

ws.onopen = () => {
    console.log(`Connected to ${gpuId}`);
};

ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    console.log('Transcription:', data.text);
};

ws.onerror = (error) => {
    console.error('WebSocket error:', error);
};
</script>
```

#### Python Client Example
```python
import websocket

# Single GPU
ws_url = "wss://3.16.124.227/ws"

# Or select specific GPU
gpu_id = "gpu2"  # gpu1, gpu2, gpu3
ws_url = f"wss://3.16.124.227/{gpu_id}/ws"

ws = websocket.create_connection(ws_url)
ws.send(audio_data)
result = ws.recv()
```

## Management

### Daily Operations

```bash
# Navigate to project directory
cd ~/event-b/whisper-live-test

# View real-time logs
docker compose logs -f

# Check container status
docker compose ps

# Restart container
docker compose restart

# Stop container
docker compose down

# Start container
docker compose up -d
```

### Update Configuration

When you modify the Caddyfile:

```bash
# Option 1: Restart container (5 second downtime)
docker compose restart

# Option 2: Reload without downtime (if supported)
docker exec whisperlive-edge caddy reload --config /etc/caddy/Caddyfile
```

### Monitor Resource Usage

```bash
# Container stats
docker stats whisperlive-edge

# Disk usage
docker system df

# View volumes
docker volume ls
```

## Security

### Network Architecture

```
Client (Your IP)
    ↓ :443 (HTTPS/WSS)
Edge Box (Public)
    ↓ :9090 (Internal - Private IP)
GPU Instance (Private)
```

### Security Groups

**Edge Box** (Public-Facing):
- Port 22 (SSH) - From your IP only
- Port 80 (HTTP) - From client IPs (redirects to HTTPS)
- Port 443 (HTTPS/WSS) - From client IPs

**GPU Instances** (Internal):
- Port 22 (SSH) - From your IP only
- Port 9090 (WhisperLive/RIVA) - From edge box private IP only

### Configure Security

```bash
# Edge box security (manage client access)
./scripts/031-configure-edge-box-security.sh

# GPU security (allow edge box access)
./scripts/030-configure-gpu-security.sh
```

### SSL Certificates

The setup uses **self-signed certificates** for HTTPS. Browsers will show a warning.

**To accept in browser:**
1. Navigate to `https://<EDGE_IP>/`
2. Click "Advanced" or "Details"
3. Click "Proceed" or "Accept Risk"

**For production with trusted certificates:**
- Use a domain name
- Configure Caddy to use Let's Encrypt (automatic)

## Troubleshooting

### Container Issues

**Problem:** Container won't start

```bash
# Check logs
cd ~/event-b/whisper-live-test
docker compose logs

# Common issues:
# 1. Port conflict (nginx running)
sudo systemctl stop nginx

# 2. Container name conflict
docker stop whisperlive-edge
docker rm whisperlive-edge
./scripts/305-setup-whisperlive-edge.sh
```

### Connection Issues

**Problem:** Cannot reach GPU via edge proxy (502 Bad Gateway)

```bash
# 1. Verify edge box can reach GPU
telnet <GPU_PRIVATE_IP> 9090
# Should connect. If timeout, check security groups.

# 2. Check GPU service is running
ssh ubuntu@<GPU_IP> 'docker ps | grep whisper'

# 3. Check Caddy logs
cd ~/event-b/whisper-live-test
docker compose logs -f
# Look for: "dial tcp <GPU_IP>:9090: i/o timeout"
```

**Problem:** WebSocket connection fails

```bash
# Check browser console for errors

# Test with curl
curl -k -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: test" \
  https://<EDGE_IP>/ws

# Should return HTTP 101 Switching Protocols
```

### SSL Certificate Issues

**Problem:** Certificate errors in browser

- Expected with self-signed certificates
- Click "Advanced" → "Proceed" in browser

**Problem:** Certificate not found

```bash
# Check certificates exist
ls -la /opt/riva/certs/
# Should show: server.crt, server.key

# If missing, create them
./scripts/010-setup-build-box.sh
```

### Performance Issues

**Problem:** Slow response times

```bash
# Check edge box resources
top
free -h
df -h

# Check Caddy stats
docker stats whisperlive-edge

# Check network latency to GPU
ping <GPU_PRIVATE_IP>
```

## Advanced Configuration

### Custom Routing Rules

Add authentication to specific GPU:

```caddy
# Require basic auth for GPU 3
handle /gpu3/* {
    basicauth {
        admin $2a$14$... # generate with: caddy hash-password
    }
    reverse_proxy 10.0.0.10:9090
}
```

### Load Balancing Across GPUs

Round-robin between two GPUs:

```caddy
handle /ws {
    reverse_proxy 52.15.199.98:9090 10.0.0.5:9090 {
        lb_policy round_robin
        health_uri /healthz
        health_interval 10s
    }
}
```

### Custom Headers

Add CORS headers:

```caddy
handle /gpu1/* {
    header {
        Access-Control-Allow-Origin "*"
        Access-Control-Allow-Methods "GET, POST, OPTIONS"
    }
    reverse_proxy 52.15.199.98:9090
}
```

### Rate Limiting

Limit requests per client:

```caddy
handle /gpu1/* {
    rate_limit {
        zone gpu1 {
            key {remote_host}
            events 100
            window 1m
        }
    }
    reverse_proxy 52.15.199.98:9090
}
```

## Backup and Recovery

### Backup Configuration

```bash
# Backup project directory
tar -czf whisper-edge-backup-$(date +%Y%m%d).tar.gz \
  ~/event-b/whisper-live-test/

# Backup just config files
mkdir -p ~/backups
cp ~/event-b/whisper-live-test/{Caddyfile,.env-http,docker-compose.yml} \
  ~/backups/
```

### Restore Configuration

```bash
# Extract backup
tar -xzf whisper-edge-backup-20251019.tar.gz -C ~/event-b/

# Restart container
cd ~/event-b/whisper-live-test
docker compose up -d
```

### Disaster Recovery

If edge box is lost, recreate on new instance:

```bash
# 1. Copy SSL certs to new instance
scp -r /opt/riva/certs new-edge-box:/opt/riva/

# 2. Restore config backup
scp whisper-edge-backup.tar.gz new-edge-box:~
ssh new-edge-box 'tar -xzf whisper-edge-backup.tar.gz'

# 3. Run setup script (will detect existing config)
./scripts/305-setup-whisperlive-edge.sh

# 4. Update security groups to new edge box IP
./scripts/030-configure-gpu-security.sh
```

## Monitoring

### Health Checks

```bash
# Edge proxy health
curl -k https://$(curl -s ifconfig.me)/healthz

# Individual GPU health (if configured)
curl -k https://$(curl -s ifconfig.me)/gpu1/healthz
curl -k https://$(curl -s ifconfig.me)/gpu2/healthz
```

### Log Monitoring

```bash
# Follow logs
docker compose logs -f

# Filter for errors
docker compose logs | grep ERROR

# Last 100 lines
docker compose logs --tail 100
```

### Automated Monitoring Script

Create a simple health check script:

```bash
#!/bin/bash
# monitor-edge.sh

EDGE_IP=$(curl -s ifconfig.me)

# Check Caddy
if ! curl -k -s https://$EDGE_IP/healthz | grep -q "OK"; then
    echo "❌ Edge proxy down!"
    exit 1
fi

# Check GPUs
for gpu in gpu1 gpu2 gpu3; do
    if ! curl -k -s https://$EDGE_IP/$gpu/healthz >/dev/null 2>&1; then
        echo "⚠️  $gpu unreachable"
    else
        echo "✅ $gpu healthy"
    fi
done
```

Run every 5 minutes with cron:
```bash
*/5 * * * * /home/ubuntu/monitor-edge.sh >> /var/log/edge-health.log 2>&1
```

## Cost Optimization

### Shutdown GPUs Overnight

Edge proxy continues running, but GPUs can be stopped:

```bash
# Stop GPU instances to save costs
./scripts/740-stop-gpu-instance.sh

# Edge proxy will return 502 until GPUs restart
# Clients should implement retry logic

# Restart in morning
./scripts/730-start-gpu-instance.sh
```

### Auto-Scaling (Advanced)

Use AWS Lambda + API Gateway to start/stop GPUs on demand.

## Frequently Asked Questions

**Q: Can I use a domain name instead of IP?**

A: Yes! Update the Caddyfile:
```caddy
https://asr.example.com {
    # Caddy will auto-obtain Let's Encrypt certificate
    ...
}
```

**Q: How many GPUs can I route to?**

A: Unlimited. Add as many `handle /gpuN/*` blocks as needed.

**Q: Does this support HTTPS only?**

A: HTTP is automatically redirected to HTTPS.

**Q: Can I run this locally (not on AWS)?**

A: Yes! Just ensure network connectivity between edge box and GPU instances.

**Q: What's the latency overhead?**

A: Minimal (~5-10ms). Caddy is very lightweight.

## See Also

- [305-setup-whisperlive-edge.md](scripts/305-setup-whisperlive-edge.md) - Setup script documentation
- `scripts/310-configure-whisperlive-gpu.sh` - GPU-side WhisperLive setup
- `scripts/030-configure-gpu-security.sh` - GPU security configuration
- `scripts/031-configure-edge-box-security.sh` - Edge security configuration
- [CLAUDE.md](../CLAUDE.md) - Overall project documentation
