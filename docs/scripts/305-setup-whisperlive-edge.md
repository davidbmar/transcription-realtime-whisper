# 305: Setup WhisperLive Edge Proxy

## Purpose
Initial setup of Caddy reverse proxy on edge EC2 instance for WhisperLive/RIVA GPU backends.

## Usage

```bash
# First time setup
./scripts/305-setup-whisperlive-edge.sh

# If container already exists, script will ask:
# "Remove existing container and recreate? (y/n)"
```

## What It Does

1. Checks SSL certificates exist at `/opt/riva/certs/`
2. Installs Docker and Docker Compose if needed
3. Creates project directory: `~/event-b/whisper-live-test/`
4. Prompts for GPU IP address and email
5. Creates `.env-http` configuration file
6. Creates `Caddyfile` for reverse proxying
7. Creates `docker-compose.yml`
8. Checks if container already exists:
   - **If exists:** Prompts to remove and recreate
   - **If new:** Creates container directly
9. Starts Caddy container
10. Verifies deployment

## Requirements

- **Run on edge EC2 instance** (not GPU instance)
- **SSL certificates** at `/opt/riva/certs/server.crt` and `/opt/riva/certs/server.key`
  - Created by `scripts/010-setup-build-box.sh`
- **Docker** and Docker Compose installed (script installs if missing)
- **Ports** 80 and 443 available (not used by nginx or other services)

## Creates

**Directory:** `~/event-b/whisper-live-test/`

**Files:**
- `.env-http` - GPU configuration (IP, port)
- `Caddyfile` - Routing rules for reverse proxy
- `docker-compose.yml` - Container configuration
- `site/index.html` - Placeholder dashboard page

**Container:** `whisperlive-edge`

**Docker Volumes:**
- `caddy_data` - SSL certificates, cache
- `caddy_config` - Caddy internal configuration

## URLs After Setup

- **Dashboard:** `https://<EDGE_IP>/`
- **WebSocket:** `wss://<EDGE_IP>/ws` → Routes to GPU
- **Health Check:** `https://<EDGE_IP>/healthz`

## Adding More GPUs

The default setup routes `/ws` to a single GPU. To support multiple GPUs with path-based routing:

### Method 1: Edit Caddyfile Manually

```bash
# Edit the configuration
nano ~/event-b/whisper-live-test/Caddyfile

# Add GPU routes (see example below)

# Save and restart
cd ~/event-b/whisper-live-test
docker compose restart
```

### Example Multi-GPU Caddyfile

```caddy
https:// {
    tls /certs/server.crt /certs/server.key

    # GPU 1 - RIVA Conformer
    handle /gpu1/ws {
        reverse_proxy 52.15.199.98:9090
    }

    # GPU 2 - WhisperLive Faster-Whisper
    handle /gpu2/ws {
        reverse_proxy 10.0.0.5:9090
    }

    # GPU 3 - Parakeet RNNT
    handle /gpu3/ws {
        reverse_proxy 10.0.0.10:9090
    }

    # Health check endpoint
    handle /healthz {
        respond "OK" 200
    }

    # Default - Serve dashboard
    handle {
        root * /srv
        file_server browse
    }

    log {
        output stdout
    }
}

# HTTP redirect to HTTPS
http:// {
    redir https://{host}{uri} permanent
}
```

### Client Usage with Multi-GPU

Update your browser client to specify GPU path:

```javascript
// Single GPU (default after initial setup)
const ws = new WebSocket('wss://3.16.124.227/ws');

// Multi-GPU (after editing Caddyfile)
const gpuId = 'gpu2';  // or gpu1, gpu3, etc.
const ws = new WebSocket(`wss://3.16.124.227/${gpuId}/ws`);
```

## Troubleshooting

### Container Already Exists

**Error:**
```
Container name "/whisperlive-edge" is already in use
```

**Solution:**

The script now handles this automatically. When you run it, you'll see:

```
⚠️  Container 'whisperlive-edge' already exists

The container will be removed and recreated with current configuration.
This preserves all config files and Docker volumes (SSL certs, cache).

Remove existing container and recreate? (y/n):
```

- Press `y` to remove and recreate (recommended)
- Press `n` to exit without changes

**Manual fix:**
```bash
docker stop whisperlive-edge
docker rm whisperlive-edge
./scripts/305-setup-whisperlive-edge.sh
```

### Port Conflict (80/443)

**Error:**
```
bind: address already in use
```

**Likely cause:** nginx or another web server is using ports 80/443

**Solution:**

The script checks for nginx and prompts you to stop it. If another service is using the ports:

```bash
# Check what's using the ports
sudo lsof -i :80
sudo lsof -i :443

# Stop the conflicting service
# Example for nginx:
sudo systemctl stop nginx
sudo systemctl disable nginx

# Re-run script
./scripts/305-setup-whisperlive-edge.sh
```

### Cannot Connect to GPU

**Error:** `502 Bad Gateway` when accessing `/ws`

**Checks:**

1. **Can edge box reach GPU?**
   ```bash
   telnet <GPU_IP> 9090
   # Should connect. If not, check security groups.
   ```

2. **Is GPU service running?**
   ```bash
   ssh ubuntu@<GPU_IP> 'docker ps | grep whisper'
   # Should show running WhisperLive container
   ```

3. **Check Caddy logs**
   ```bash
   cd ~/event-b/whisper-live-test
   docker compose logs -f
   # Look for connection errors
   ```

4. **Verify security groups**
   ```bash
   # GPU must allow edge box IP on port 9090
   ./scripts/030-configure-gpu-security.sh
   ```

### SSL Certificate Errors

**Error:** `SSL certificates not found at /opt/riva/certs/`

**Solution:**

```bash
# Run build box setup first (creates self-signed certs)
./scripts/010-setup-build-box.sh

# Or copy existing certificates
sudo mkdir -p /opt/riva/certs
sudo cp /path/to/server.crt /opt/riva/certs/
sudo cp /path/to/server.key /opt/riva/certs/
sudo chmod 644 /opt/riva/certs/server.crt
sudo chmod 600 /opt/riva/certs/server.key
```

## Management Commands

All commands assume you're in the project directory:

```bash
cd ~/event-b/whisper-live-test
```

### View Logs
```bash
docker compose logs -f
```

### Restart Container
```bash
docker compose restart
```

### Stop Container
```bash
docker compose down
```

### Start Container
```bash
docker compose up -d
```

### Check Status
```bash
docker compose ps
```

### Rebuild Container
```bash
docker compose down
docker compose up -d --force-recreate
```

## What Gets Preserved on Recreate

When you remove and recreate the container (via script or manually):

### ✅ Preserved
- Configuration files (`Caddyfile`, `.env-http`, `docker-compose.yml`)
- Docker volumes (`caddy_data`, `caddy_config`)
- SSL certificates and cache
- Site files (`site/` directory)
- All your GPU routing configuration

### ❌ Lost
- Active WebSocket connections (clients will need to reconnect)
- Container logs (use `docker compose logs` before removing if needed)
- In-memory state (minimal for Caddy)

**Downtime:** ~5 seconds for container recreation

## Configuration Files

### .env-http
```bash
# Example content
DOMAIN=52.15.199.98
EMAIL=user@example.com
GPU_HOST=52.15.199.98
GPU_PORT=9090
MODEL=Systran/faster-whisper-small.en
LANGUAGE=en
```

### docker-compose.yml
```yaml
version: "3.9"

services:
  caddy:
    image: caddy:2.8
    container_name: whisperlive-edge
    restart: unless-stopped
    ports:
      - "80:80"     # HTTP (redirects to HTTPS)
      - "443:443"   # HTTPS
    env_file:
      - .env-http
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./site:/srv
      - /opt/riva/certs:/certs:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

## Next Steps

1. **Configure GPU security** to allow edge box access:
   ```bash
   ./scripts/030-configure-gpu-security.sh
   ```

2. **Set up WhisperLive on GPU** (if not already done):
   ```bash
   ./scripts/310-configure-whisperlive-gpu.sh
   ```

3. **Configure edge box security** to manage client access:
   ```bash
   ./scripts/031-configure-edge-box-security.sh
   ```

4. **Deploy browser clients**:
   ```bash
   ./scripts/320-update-edge-clients.sh
   ```

5. **Test end-to-end**:
   ```bash
   ./scripts/325-test-whisperlive-connection.sh
   ```

## See Also

- [EDGE_PROXY_SETUP.md](../EDGE_PROXY_SETUP.md) - Overall edge proxy architecture and multi-GPU guide
- `scripts/310-configure-whisperlive-gpu.sh` - GPU-side WhisperLive setup
- `scripts/030-configure-gpu-security.sh` - GPU security configuration
- `scripts/031-configure-edge-box-security.sh` - Edge box security configuration
