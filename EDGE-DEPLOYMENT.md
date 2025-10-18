# WhisperLive Edge Proxy Deployment Guide

This setup creates an **edge EC2 instance** that serves a browser app over HTTPS/WSS and reverse-proxies WebSocket audio to WhisperLive running on a private GPU instance.

## Architecture

```
Browser (mic) --HTTPS/WSS--> Edge EC2 (Caddy) --WS--> GPU Instance (WhisperLive)
              :443                                     :9090 (private)
```

**Benefits:**
- GPU instance stays private (no public IP needed)
- Browser mic access works (requires HTTPS)
- Automatic TLS via Let's Encrypt
- Easy to add auth and rate limiting

## Prerequisites

1. **GPU instance** running WhisperLive on port 9090 (private, no public IP)
2. **Edge EC2** (t3.micro is sufficient) with:
   - Public IP
   - Security Group: allow ports 22, 80, 443
   - Docker installed
3. **DNS A record** pointing to edge EC2 public IP (e.g., `asr.yourdomain.com`)

## Quick Start

### 1. Configure Security Group

Allow this edge machine to access GPU port 9090:

```bash
./scripts/040-configure-edge-security.sh
```

This script will:
- Detect the edge machine's public IP
- Add a security group rule to allow access to GPU port 9090
- Test connectivity to WhisperLive on the GPU

### 2. Configure `.env-http`

Edit the file and fill in your values:

```bash
DOMAIN=3.138.85.115             # Your domain or edge public IP
EMAIL=you@example.com            # For Let's Encrypt notifications
GPU_HOST=3.138.85.115           # GPU instance IP (private or public)
GPU_PORT=9090                    # WhisperLive port
MODEL=Systran/faster-whisper-small.en
```

### 3. Start the service

```bash
docker compose up -d
```

Watch the logs to see Let's Encrypt certificate provisioning:

```bash
docker compose logs -f
```

### 4. Test

1. Open `https://3.16.124.227/` in Chrome/Edge (or your domain if configured)
2. Accept the self-signed certificate warning (Advanced → Proceed)
3. Allow microphone access
4. Click "Start Recording"
5. Speak and watch transcripts appear in real-time

**Note**: For production use with proper HTTPS, get a domain and update DOMAIN in `.env-http`

## File Structure

```
whisper-live-test/
├── .env-http              # Configuration (EDIT THIS FIRST)
├── docker-compose.yml     # Docker Compose setup
├── Caddyfile             # Caddy reverse proxy config
└── site/
    └── index.html        # Browser client app
```

## Management Commands

```bash
# Start services
docker compose up -d

# View logs
docker compose logs -f

# Stop services
docker compose down

# Restart after config changes
docker compose restart

# Check status
docker compose ps
```

## Optional: Enable Basic Auth

To add password protection:

1. Generate a password hash:

```bash
docker run --rm caddy:2.8 caddy hash-password --plaintext 'yourpassword'
```

2. Edit `Caddyfile` and uncomment the basicauth section:

```caddy
basicauth / {
    user JDJhJDE0JDZ...  # paste hash here
}
```

3. Restart: `docker compose restart`

## Troubleshooting

### Certificate issues

- Ensure your domain's A record points to the edge EC2 public IP
- Port 80 must be accessible for Let's Encrypt ACME challenge
- Check logs: `docker compose logs caddy`

### WebSocket connection fails

- Verify GPU instance private IP in `.env-http`
- Ensure edge EC2 can reach GPU on port 9090:
  ```bash
  nc -zv <GPU_PRIVATE_IP> 9090
  ```
- Check GPU Security Group allows inbound 9090 from edge SG

### Browser mic not working

- Must use HTTPS (not HTTP)
- Some browsers block mic on self-signed certs (use Let's Encrypt)
- Check browser console for errors

## Security Notes

### Current Setup (Basic)
- GPU instance: **private only** (no public IP, SG restricts to edge)
- Edge instance: **public** (serves browser clients)
- TLS: **automatic** via Let's Encrypt

### Hardening Options
1. **Basic Auth**: Add password protection (see above)
2. **IP Allowlist**: Restrict edge SG to known client IPs
3. **Rate Limiting**: Enable in Caddyfile (commented out)
4. **WAF**: Add CloudFlare or AWS WAF in front of edge

## Cost Optimization

- Edge instance: ~$0.01/hour (t3.micro)
- Can be stopped when not in use
- Consider spot instances for further savings

## Deployment Checklist

- [ ] DNS A record created and propagated
- [ ] `.env-http` configured with correct values
- [ ] Edge EC2 security group allows ports 22, 80, 443
- [ ] GPU security group allows port 9090 from edge SG only
- [ ] Docker installed on edge EC2
- [ ] WhisperLive running on GPU instance
- [ ] `docker compose up -d` executed
- [ ] HTTPS certificate issued (check logs)
- [ ] Browser test successful

## Support

For issues related to:
- **WhisperLive server**: Check WhisperLive documentation
- **Edge proxy**: Review Caddy logs and this guide
- **AWS networking**: Verify security groups and VPC setup
