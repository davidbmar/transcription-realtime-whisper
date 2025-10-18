# WhisperLive Edge Proxy Deployment Guide (300 Series)

Complete deployment guide for WhisperLive real-time speech recognition with edge proxy architecture.

## Architecture Overview

```
Browser (Client)          Edge EC2               GPU EC2
   |                         |                      |
   | HTTPS/WSS (443)        |                      |
   |----------------------->|                      |
   |                         |                      |
   |                         | WebSocket (9090)    |
   |                         |-------------------->|
   |                         |                      |
   |<-- Transcriptions ------|<--------------------|

Components:
- Browser: Real-time audio capture (Float32 PCM @ 16kHz)
- Edge: Caddy reverse proxy with SSL termination
- GPU: WhisperLive faster-whisper streaming ASR
```

## Prerequisites

### Before You Start

1. **Complete scripts 005-040**:
   - 005: Configuration setup
   - 010: Build box prerequisites
   - 020-030: GPU instance and security
   - 031: Build box security
   - 040: Edge security configuration

2. **Required Resources**:
   - GPU EC2 instance (g4dn.xlarge) with NVIDIA drivers
   - Edge EC2 instance (t3.medium or similar)
   - SSL certificates at `/opt/riva/certs/` (created by script 010)
   - Configured AWS security groups
   - SSH access to both instances

3. **Environment Setup**:
   - `.env` file with GPU instance details
   - AWS CLI configured
   - SSH key available (default: `~/.ssh/dbm-sep23-2025.pem`)

## Deployment Steps

### Step 1: Deploy Edge Proxy (305)

**Run on: Edge EC2 Instance**

```bash
cd ~/event-b/whisper-live-test
./scripts/305-setup-whisperlive-edge.sh
```

**What it does**:
- Installs Docker and Docker Compose
- Creates project directory structure
- Configures Caddy reverse proxy
- Deploys Docker Compose setup
- Starts Caddy container on ports 80/443

**Expected output**:
```
✅ WHISPERLIVE EDGE PROXY DEPLOYED

Edge Proxy Details:
  - Location: ~/event-b/whisper-live-test
  - HTTPS URL: https://YOUR_EDGE_IP/
  - WebSocket: wss://YOUR_EDGE_IP/ws
```

**Files created**:
- `~/event-b/whisper-live-test/.env-http`
- `~/event-b/whisper-live-test/Caddyfile`
- `~/event-b/whisper-live-test/docker-compose.yml`
- `~/event-b/whisper-live-test/site/index.html` (placeholder)

### Step 2: Configure WhisperLive on GPU (310)

**Run on: Build Box or Edge (will SSH to GPU)**

```bash
cd ~/event-b/whisper-live-test
./scripts/310-configure-whisperlive-gpu.sh
```

**What it does**:
- Installs WhisperLive from Collabora GitHub
- Installs faster-whisper and dependencies
- Downloads Whisper models (small.en)
- Creates systemd service
- Starts WhisperLive on port 9090

**Expected output**:
```
✅ WHISPERLIVE GPU CONFIGURATION COMPLETE

WhisperLive Details:
  - Location: ~/whisperlive/WhisperLive
  - Service: whisperlive.service
  - Port: 9090 (WebSocket)
```

**On GPU instance**:
```bash
# Check service status
sudo systemctl status whisperlive

# View logs
sudo journalctl -u whisperlive -f

# Restart if needed
sudo systemctl restart whisperlive
```

### Step 3: Configure Security Groups (040)

**Run on: Build Box or Edge**

If not already done, configure security groups to allow edge→GPU access:

```bash
cd ~/event-b/whisper-live-test
./scripts/040-configure-edge-security.sh
```

**What it does**:
- Detects edge public IP
- Adds security group rule for port 9090
- Tests connectivity to GPU

**Expected output**:
```
✅ Edge Security Configuration Complete!
Edge machine X.X.X.X can now access GPU port 9090
```

### Step 4: Deploy Browser Clients (320)

**Run on: Edge EC2 Instance**

```bash
cd ~/event-b/whisper-live-test
./scripts/320-update-edge-clients.sh
```

**What it does**:
- Deploys index.html (main UI)
- Deploys test-whisper.html (test client)
- Copies Python test client
- Restarts Caddy

**Expected output**:
```
✅ BROWSER CLIENTS DEPLOYED

Available URLs:
  - Main UI: https://YOUR_EDGE_IP/
  - Test UI: https://YOUR_EDGE_IP/test-whisper.html
```

**Client features**:
- Real-time transcription display
- Model selection (small, medium, large)
- Language configuration
- Partial vs Final transcript highlighting
- Modern responsive UI

### Step 5: Test End-to-End (315)

**Run on: Edge EC2 Instance**

```bash
cd ~/event-b/whisper-live-test
./scripts/315-test-whisperlive-connection.sh
```

**What it does**:
- Tests Python dependencies
- Tests network connectivity
- Tests WebSocket connection
- Sends test audio
- Verifies browser client accessibility

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

## Using the System

### Browser Access

1. **Open browser**:
   ```
   https://YOUR_EDGE_IP/
   ```

2. **Accept SSL certificate warning** (self-signed certificate)

3. **Select model and language** (optional, defaults work fine)

4. **Click "Start Recording"**

5. **Allow microphone access** when prompted

6. **Speak clearly** and watch transcriptions appear in real-time!

### Understanding Transcriptions

WhisperLive sends two types of transcriptions:

- **Partial** (gray, italic): Interim results that may change
- **Final** (green border): Completed segments that won't change

Transcriptions include:
- Start/end timestamps
- Full text
- Completion status

### Python Test Client

For debugging or automation:

```bash
cd ~/event-b/whisper-live-test
python3 test_client.py
```

This will:
- Connect to WhisperLive
- Send a test audio file
- Display transcription responses

## Important Technical Details

### Audio Format Requirements

**CRITICAL**: WhisperLive expects **Float32 PCM**, NOT Int16!

- **Sample Rate**: 16,000 Hz
- **Channels**: 1 (mono)
- **Format**: Float32 PCM (32-bit float, little-endian)
- **Values**: Float in range [-1.0, +1.0]
- **Chunk Size**: 4096 samples = 16,384 bytes

### Browser Client Implementation

```javascript
// Correct: Send Float32Array directly
audioContext = new AudioContext({ sampleRate: 16000 });
processor = audioContext.createScriptProcessor(4096, 1, 1);

processor.onaudioprocess = (e) => {
    const audioData = e.inputBuffer.getChannelData(0);  // Float32Array
    ws.send(audioData.buffer);  // Send raw ArrayBuffer
};
```

**Do NOT**:
- Convert to Int16
- Send WebM/Opus compressed audio
- Use MediaRecorder (sends compressed audio)

See `FLOAT32_FIX.md` for full details.

### WebSocket Message Format

**Client → Server (Config)**:
```json
{
  "uid": "browser-123456",
  "task": "transcribe",
  "language": "en",
  "model": "Systran/faster-whisper-small.en",
  "use_vad": false
}
```

**Server → Client (Ready)**:
```json
{
  "uid": "browser-123456",
  "message": "SERVER_READY",
  "backend": "faster_whisper"
}
```

**Server → Client (Transcription)**:
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

## Troubleshooting

### No Transcriptions Appearing

**Most common issue**: Audio format!

1. **Check browser console** for errors
2. **Verify Float32 format**:
   ```javascript
   console.log(audioContext.sampleRate);  // Should be 16000
   console.log(audioData.constructor.name);  // Should be "Float32Array"
   ```
3. **Check GPU logs**:
   ```bash
   ssh ubuntu@GPU_IP sudo journalctl -u whisperlive -f
   ```

### Connection Refused

1. **Check WhisperLive is running**:
   ```bash
   ssh ubuntu@GPU_IP sudo systemctl status whisperlive
   ```

2. **Check security groups**:
   - Edge IP allowed on GPU port 9090?
   - Client IP allowed on Edge ports 80/443?

3. **Test connectivity**:
   ```bash
   nc -zv GPU_IP 9090
   ```

### SSL Certificate Errors

1. **Verify certificates exist**:
   ```bash
   ls -lh /opt/riva/certs/
   ```

2. **Check Caddy logs**:
   ```bash
   docker compose logs -f
   ```

3. **Recreate certificates if needed**:
   ```bash
   openssl req -x509 -newkey rsa:4096 -nodes \
     -keyout /opt/riva/certs/server.key \
     -out /opt/riva/certs/server.crt \
     -days 365 \
     -subj "/C=US/ST=State/L=City/O=Org/CN=localhost"
   ```

### WebSocket 404 Errors

1. **Check Caddyfile**:
   ```bash
   cat ~/event-b/whisper-live-test/Caddyfile
   ```
   Should have `handle /ws` block

2. **Restart Caddy**:
   ```bash
   docker compose restart caddy
   ```

### Buffer Size Errors

This means wrong audio format (Int16 instead of Float32).

**Fix**: Update browser client to send Float32:
```bash
./scripts/320-update-edge-clients.sh
```

## Management Commands

### Edge Proxy (Caddy)

```bash
cd ~/event-b/whisper-live-test

# View logs
docker compose logs -f

# Restart
docker compose restart

# Stop
docker compose down

# Start
docker compose up -d

# Status
docker compose ps
```

### GPU WhisperLive Service

```bash
# SSH to GPU first
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@GPU_IP

# Check status
sudo systemctl status whisperlive

# View logs
sudo journalctl -u whisperlive -f

# Restart
sudo systemctl restart whisperlive

# Stop
sudo systemctl stop whisperlive

# Start
sudo systemctl start whisperlive
```

## Cost Optimization

### Shutdown GPU When Not In Use

```bash
# From build box
cd /opt/riva/nvidia-riva-conformer-streaming
./scripts/210-shutdown-gpu.sh
```

### Startup and Restore

```bash
# From build box
cd /opt/riva/nvidia-riva-conformer-streaming
./scripts/220-startup-restore.sh
```

**Note**: Edge proxy can stay running (cheap t3.medium). Only GPU needs to be shut down.

## Additional Resources

- **FLOAT32_FIX.md** - Detailed audio format explanation
- **EDGE-DEPLOYMENT.md** - Edge architecture details
- **CHATGPT_PROMPT.md** - Debugging guide
- **test_client.py** - Python WebSocket test client

## Summary of Scripts

| Script | Run On | Purpose |
|--------|--------|---------|
| 305-setup-whisperlive-edge.sh | Edge EC2 | Deploy Caddy reverse proxy |
| 310-configure-whisperlive-gpu.sh | Build/Edge | Install WhisperLive on GPU |
| 040-configure-edge-security.sh | Build/Edge | Configure security groups |
| 320-update-edge-clients.sh | Edge EC2 | Deploy browser clients |
| 315-test-whisperlive-connection.sh | Edge EC2 | Test end-to-end connectivity |

## Quick Start Command Sequence

**On Edge EC2**:
```bash
cd ~/event-b/whisper-live-test
./scripts/305-setup-whisperlive-edge.sh
./scripts/310-configure-whisperlive-gpu.sh  # Will SSH to GPU
./scripts/040-configure-edge-security.sh
./scripts/320-update-edge-clients.sh
./scripts/315-test-whisperlive-connection.sh
```

**Then open browser**:
```
https://YOUR_EDGE_IP/
```

**Start recording and speak!** 🎤
