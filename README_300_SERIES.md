## WhisperLive Edge Proxy - 300 Series Scripts

**Real-time speech recognition with edge proxy architecture**

### 🎯 What This Is

The 300 series scripts deploy **WhisperLive faster-whisper** streaming ASR with a secure edge proxy architecture:

```
Browser → Edge EC2 (Caddy HTTPS) → GPU EC2 (WhisperLive)
```

This gives you:
- ✅ Real-time browser-based speech recognition
- ✅ Secure HTTPS/WSS connections
- ✅ Private GPU instance (not publicly exposed)
- ✅ Easy client access through edge proxy
- ✅ Open-source Whisper models

### 📁 Files Created

#### Scripts (in `scripts/` directory)

| Script | Purpose |
|--------|---------|
| `300----------WHISPERLIVE-EDGE----------.sh` | Separator (category marker) |
| `300-whisperlive-edge-category.sh` | Category description and overview |
| `305-setup-whisperlive-edge.sh` | Deploy Caddy reverse proxy on edge EC2 |
| `310-configure-whisperlive-gpu.sh` | Install WhisperLive on GPU instance |
| `315-test-whisperlive-connection.sh` | Test end-to-end connectivity |
| `320-update-edge-clients.sh` | Deploy/update browser client files |

#### Configuration Files

| File | Created By | Purpose |
|------|-----------|---------|
| `.env-http` | Script 305 | Edge proxy configuration |
| `Caddyfile` | Script 305 | Caddy reverse proxy config |
| `docker-compose.yml` | Script 305 | Docker Compose for Caddy |
| `site/index.html` | Script 320 | Main browser UI |
| `site/test-whisper.html` | Script 320 | Simple test client |
| `test_client.py` | Script 320 | Python debugging client |

#### Documentation

| Document | Purpose |
|----------|---------|
| `COMPLETE_DEPLOYMENT_GUIDE.md` | Full deployment guide (005-320) |
| `DEPLOYMENT_GUIDE_300_SERIES.md` | Detailed 300 series guide |
| `FLOAT32_FIX.md` | Audio format requirements (critical!) |
| `README_300_SERIES.md` | This file |

### 🚀 Quick Start

#### Prerequisites Completed (005-040)

Before running 300 series, you must complete:

- ✅ Script 005: Configuration setup
- ✅ Script 010: Build box prerequisites
- ✅ Script 020: GPU instance deployed
- ✅ Script 030: GPU security configured
- ✅ Optional: Scripts 031, 040 (security groups)

#### Deploy WhisperLive Edge (5 commands)

**On Edge EC2**:

```bash
cd ~/event-b/whisper-live-test

# 1. Deploy edge proxy
./scripts/305-setup-whisperlive-edge.sh

# 2. Install WhisperLive on GPU (will SSH to GPU)
./scripts/310-configure-whisperlive-gpu.sh

# 3. Configure security groups
./scripts/040-configure-edge-security.sh

# 4. Deploy browser clients
./scripts/320-update-edge-clients.sh

# 5. Test everything
./scripts/315-test-whisperlive-connection.sh
```

**Total time**: ~20 minutes

**Then open browser**: `https://YOUR_EDGE_IP/`

### 📋 Deployment Steps Explained

#### 1. Setup Edge Proxy (305)

Deploys Caddy reverse proxy on edge EC2:
- Installs Docker and Docker Compose
- Creates Caddyfile for WebSocket proxying
- Starts HTTPS server on ports 80/443
- Proxies `/ws` to GPU WhisperLive

**Output**: `https://EDGE_IP/` (placeholder page)

---

#### 2. Configure GPU (310)

Installs WhisperLive on GPU instance:
- Clones WhisperLive from GitHub
- Installs faster-whisper
- Downloads Whisper models
- Creates systemd service on port 9090

**Output**: WhisperLive service running on GPU

---

#### 3. Configure Security (040)

Opens network access:
- Detects edge public IP
- Allows edge→GPU on port 9090
- Tests connectivity

**Output**: Edge can reach GPU WhisperLive

---

#### 4. Deploy Clients (320)

Deploys browser UIs:
- Copies HTML/JS client files
- Restarts Caddy
- Verifies deployment

**Output**: Working browser clients at `https://EDGE_IP/`

---

#### 5. Test Everything (315)

Validates full chain:
- Tests WebSocket connection
- Sends test audio
- Checks transcriptions
- Verifies browser access

**Output**: Confirmation all systems working

---

### 🎤 Using the System

1. **Open browser**: `https://YOUR_EDGE_IP/`
2. **Accept SSL warning** (self-signed cert)
3. **Click "Start Recording"**
4. **Allow microphone** when prompted
5. **Speak clearly** and watch real-time transcriptions!

### ⚙️ Architecture

```
┌──────────────┐
│   Browser    │  Float32 PCM @ 16kHz
│   (Client)   │  AudioContext API
└──────┬───────┘
       │ WSS (443)
       │ HTTPS
       ▼
┌──────────────┐
│  Edge EC2    │  Caddy 2.8
│  (Proxy)     │  SSL Termination
│              │  WebSocket Proxy
└──────┬───────┘
       │ WS (9090)
       │ Float32 PCM
       ▼
┌──────────────┐
│  GPU EC2     │  WhisperLive
│ (g4dn.xlarge)│  faster-whisper
│              │  CUDA acceleration
└──────────────┘
       │
       ▼
  Transcriptions
  (JSON segments)
```

### 🔧 Management

#### Edge Proxy (Caddy)

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
```

#### GPU WhisperLive

```bash
# SSH to GPU
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@GPU_IP

# Status
sudo systemctl status whisperlive

# Logs
sudo journalctl -u whisperlive -f

# Restart
sudo systemctl restart whisperlive
```

### 🎯 Key Technical Details

#### Audio Format (CRITICAL!)

WhisperLive expects **Float32 PCM**, NOT Int16:

- **Sample Rate**: 16,000 Hz
- **Channels**: 1 (mono)
- **Format**: Float32 PCM (32-bit float)
- **Values**: Range [-1.0, +1.0]

**Browser implementation**:
```javascript
// Create 16kHz AudioContext
audioContext = new AudioContext({ sampleRate: 16000 });

// Send Float32 directly (NO conversion!)
processor.onaudioprocess = (e) => {
    const audioData = e.inputBuffer.getChannelData(0);  // Float32Array
    ws.send(audioData.buffer);  // Send raw ArrayBuffer
};
```

**Do NOT**:
- ❌ Convert to Int16
- ❌ Use MediaRecorder (sends WebM/Opus)
- ❌ Send compressed audio

See `FLOAT32_FIX.md` for full details.

#### WebSocket Protocol

**Client → Server (config)**:
```json
{
  "uid": "browser-123",
  "task": "transcribe",
  "language": "en",
  "model": "Systran/faster-whisper-small.en",
  "use_vad": false
}
```

**Server → Client (transcription)**:
```json
{
  "uid": "browser-123",
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

### 🐛 Troubleshooting

#### No Transcriptions

**Most common**: Wrong audio format!

✅ **Fix**: Ensure using Float32 PCM @ 16kHz

Check browser console:
```javascript
console.log(audioContext.sampleRate);  // Must be 16000
console.log(audioData.constructor.name);  // Must be "Float32Array"
```

#### Connection Refused

✅ **Fix**: Check security groups and services

```bash
# Test connectivity
nc -zv GPU_IP 9090

# Check WhisperLive running
ssh ubuntu@GPU_IP sudo systemctl status whisperlive

# Re-run security script
./scripts/040-configure-edge-security.sh
```

#### SSL Errors

✅ **Fix**: Verify certificates exist

```bash
ls -lh /opt/riva/certs/
# Should show server.crt and server.key
```

### 📊 Cost Optimization

| Component | Cost/Hour | When to Run |
|-----------|-----------|-------------|
| GPU (g4dn.xlarge) | $0.526 | Only when transcribing |
| Edge (t3.medium) | $0.042 | Can run 24/7 |

**Recommendation**:
- Shut down GPU when not in use (~$12/day savings)
- Keep edge running 24/7 (only $1/day)

**Commands**:
```bash
# Shutdown GPU
./scripts/210-shutdown-gpu.sh

# Startup GPU
./scripts/220-startup-restore.sh
```

### 📚 Documentation

| Document | What It Covers |
|----------|---------------|
| `COMPLETE_DEPLOYMENT_GUIDE.md` | Full guide from zero to production (005-320) |
| `DEPLOYMENT_GUIDE_300_SERIES.md` | Detailed 300 series walkthrough |
| `FLOAT32_FIX.md` | Audio format requirements and fixes |
| `EDGE-DEPLOYMENT.md` | Edge architecture details |
| `README_300_SERIES.md` | This quick reference |

### ✅ Success Checklist

Deploy checklist:
- [ ] Completed scripts 005-040
- [ ] Edge EC2 instance available
- [ ] GPU EC2 instance running
- [ ] SSL certs at `/opt/riva/certs/`
- [ ] Ran 305: Edge proxy deployed
- [ ] Ran 310: WhisperLive on GPU
- [ ] Ran 040: Security configured
- [ ] Ran 320: Clients deployed
- [ ] Ran 315: Tests passed
- [ ] Browser opens `https://EDGE_IP/`
- [ ] Can start recording
- [ ] Transcriptions appear when speaking

### 🎓 Learning Resources

**WhisperLive**:
- GitHub: https://github.com/collabora/WhisperLive
- Uses faster-whisper for CUDA-accelerated inference

**Whisper Models**:
- small.en: Fast, English-only, ~244MB
- medium.en: Better accuracy, English-only, ~769MB
- large-v2/v3: Best quality, multilingual, ~1.5GB

**Caddy**:
- Docs: https://caddyserver.com/docs/
- Automatic HTTPS and WebSocket support

### 💡 Tips

1. **Test with test-whisper.html first** - simpler UI, easier debugging
2. **Check browser console** - shows WebSocket messages
3. **Use test_client.py** - Python client for debugging
4. **Monitor GPU logs** - `sudo journalctl -u whisperlive -f`
5. **Restart services** - fixes most transient issues

### 🆘 Getting Help

**Logs to check**:
```bash
# Edge Caddy logs
docker compose logs -f

# GPU WhisperLive logs
ssh ubuntu@GPU_IP sudo journalctl -u whisperlive -f

# Script execution logs
ls -lh logs/
```

**When asking for help, provide**:
1. Which script failed?
2. Error message from logs
3. Output of `docker compose ps` (edge)
4. Output of `sudo systemctl status whisperlive` (GPU)
5. Browser console errors

### 🎉 What You Built

You now have a production-ready real-time speech recognition system:

- ✅ Secure HTTPS/WSS browser access
- ✅ Private GPU instance (not exposed)
- ✅ Open-source Whisper models
- ✅ Real-time streaming transcription
- ✅ Multiple language support
- ✅ Scalable architecture
- ✅ Cost-optimized (shutdown when idle)

**Enjoy transcribing!** 🎤✨

---

*For complete details, see `COMPLETE_DEPLOYMENT_GUIDE.md`*
