# Transcription Realtime Whisper

**Production-ready real-time speech recognition using NVIDIA Riva and WhisperLive**

## Overview

This repository provides complete deployment automation for two real-time speech recognition architectures:

1. **NVIDIA Riva Conformer-CTC** - Enterprise-grade streaming ASR with gRPC
2. **WhisperLive faster-whisper** - Open-source Whisper streaming with WebSocket

Both support browser-based real-time transcription with secure edge proxy architecture.

## Architecture

### WhisperLive Edge Proxy (Recommended for Quick Start)

```
Browser → Edge EC2 (Caddy HTTPS) → GPU EC2 (WhisperLive)
         :443 WSS                   :9090 WS
```

- **Edge**: Caddy reverse proxy with SSL termination
- **GPU**: WhisperLive faster-whisper streaming ASR
- **Browser**: Real-time Float32 PCM @ 16kHz audio

### NVIDIA Riva Architecture

```
Browser → Build Box (WebSocket Bridge) → GPU EC2 (Riva)
         :8443 WSS                       :50051 gRPC
```

- **Build Box**: Python WebSocket bridge to gRPC
- **GPU**: NVIDIA Riva 2.19 Conformer-CTC-XL streaming
- **Browser**: Real-time audio streaming

## Quick Start

### Prerequisites

- AWS account with EC2 permissions
- SSH key pair
- For Riva: NVIDIA NGC API key

### Option A: WhisperLive Edge (Scripts 300-320)

**Fastest deployment - ~20 minutes**

```bash
# 1. Clone repository
git clone https://github.com/YOUR_USERNAME/transcription-realtime-whisper.git
cd transcription-realtime-whisper

# 2. Initial setup (on build box)
./scripts/005-setup-configuration.sh
./scripts/010-setup-build-box.sh
./scripts/020-deploy-gpu-instance.sh
./scripts/030-configure-gpu-security.sh

# 3. WhisperLive deployment (on edge EC2)
./scripts/305-setup-whisperlive-edge.sh
./scripts/310-configure-whisperlive-gpu.sh
./scripts/040-configure-edge-security.sh
./scripts/320-update-edge-clients.sh
./scripts/315-test-whisperlive-connection.sh

# 4. Open browser
open https://YOUR_EDGE_IP/
```

### Option B: NVIDIA Riva (Scripts 100-165)

**Enterprise-grade ASR - ~40 minutes**

```bash
# After initial setup (005-030), deploy Riva:
./scripts/125-deploy-conformer-from-s3-cache.sh
./scripts/126-validate-conformer-deployment.sh
./scripts/155-deploy-buildbox-websocket-bridge-service.sh
./scripts/160-deploy-buildbox-demo-https-server.sh

# Open browser
open https://BUILD_BOX_IP:8444/demo.html
```

## Documentation

### Getting Started

- **[COMPLETE_DEPLOYMENT_GUIDE.md](COMPLETE_DEPLOYMENT_GUIDE.md)** - Full deployment guide (005-320)
- **[README_300_SERIES.md](README_300_SERIES.md)** - WhisperLive quick start
- **[DEPLOYMENT_GUIDE_300_SERIES.md](DEPLOYMENT_GUIDE_300_SERIES.md)** - Detailed WhisperLive guide

### Technical Deep-Dives

- **[FLOAT32_FIX.md](FLOAT32_FIX.md)** - Audio format requirements (critical!)
- **[EDGE-DEPLOYMENT.md](EDGE-DEPLOYMENT.md)** - Edge architecture details
- **[CLAUDE.md](CLAUDE.md)** - Project overview for AI assistants

### NVIDIA Riva

- **[README.md](README.md)** - Original Riva deployment guide
- **[STREAMING_ASR_BEST_PRACTICES.md](STREAMING_ASR_BEST_PRACTICES.md)**
- **[TWO_PASS_ASR_ARCHITECTURE_COMPARISON.txt](TWO_PASS_ASR_ARCHITECTURE_COMPARISON.txt)**

## Script Reference

### Setup Scripts (005-040)

| Script | Purpose | Time |
|--------|---------|------|
| 005 | Configuration setup | 5 min |
| 010 | Build box prerequisites | 5 min |
| 020 | Deploy GPU instance | 10 min |
| 030 | GPU security groups | 1 min |
| 031 | Build box security groups | 2 min |
| 040 | Edge security groups | 1 min |

### WhisperLive Scripts (300-320)

| Script | Purpose | Time |
|--------|---------|------|
| 305 | Setup edge proxy | 5 min |
| 310 | Configure WhisperLive GPU | 10 min |
| 315 | Test end-to-end | 1 min |
| 320 | Deploy browser clients | 1 min |

### NVIDIA Riva Scripts (100-165)

| Script | Purpose | Time |
|--------|---------|------|
| 125 | Deploy Conformer from S3 cache | 5 min |
| 126 | Validate Conformer deployment | 2 min |
| 155 | Deploy WebSocket bridge | 3 min |
| 160 | Deploy HTTPS demo server | 2 min |

### Operations Scripts (200+)

| Script | Purpose |
|--------|---------|
| 210 | Shutdown GPU (save costs) |
| 220 | Startup and restore GPU |

## Features

### WhisperLive

- ✅ Open-source (no API keys required)
- ✅ Multiple Whisper models (small, medium, large)
- ✅ Multi-language support
- ✅ Edge proxy architecture (secure)
- ✅ Float32 PCM audio (browser AudioContext)
- ✅ WebSocket protocol
- ✅ Systemd service (auto-restart)

### NVIDIA Riva

- ✅ Enterprise-grade accuracy
- ✅ Conformer-CTC-XL streaming model
- ✅ Low latency (40ms timesteps)
- ✅ gRPC protocol
- ✅ Docker deployment
- ✅ CUDA-accelerated

## Browser Clients

Both systems include modern browser UIs:

- Real-time transcription display
- Model/language selection
- Partial vs Final transcript highlighting
- Timestamp display
- Responsive design
- HTTPS/WSS secure connections

## Cost Optimization

| Component | Instance | Cost/Hour | Recommendation |
|-----------|----------|-----------|----------------|
| GPU | g4dn.xlarge | $0.526 | Shutdown when idle |
| Edge | t3.medium | $0.042 | Run 24/7 |
| Build Box | t3.small | $0.021 | Optional |

**Daily savings**: ~$12/day by shutting down GPU overnight

Commands:
```bash
./scripts/210-shutdown-gpu.sh    # Stop GPU
./scripts/220-startup-restore.sh # Start GPU
```

## Critical Technical Details

### Audio Format (WhisperLive)

**CRITICAL**: WhisperLive expects **Float32 PCM**, NOT Int16!

- Sample Rate: 16,000 Hz
- Channels: 1 (mono)
- Format: Float32 PCM (32-bit float)
- Values: Range [-1.0, +1.0]

Browser implementation:
```javascript
audioContext = new AudioContext({ sampleRate: 16000 });
processor = audioContext.createScriptProcessor(4096, 1, 1);

processor.onaudioprocess = (e) => {
    const audioData = e.inputBuffer.getChannelData(0);  // Float32Array
    ws.send(audioData.buffer);  // Send raw ArrayBuffer
};
```

See [FLOAT32_FIX.md](FLOAT32_FIX.md) for complete details.

## Troubleshooting

### WhisperLive: No Transcriptions

**Most common**: Wrong audio format (Int16 instead of Float32)

✅ **Fix**: Ensure browser sends Float32 PCM @ 16kHz

### Connection Refused

✅ **Fix**: Check security groups and services

```bash
# Test connectivity
nc -zv GPU_IP 9090  # WhisperLive
nc -zv GPU_IP 50051 # Riva

# Check services
sudo systemctl status whisperlive  # WhisperLive
docker logs riva-server            # Riva
```

### SSL Certificate Errors

✅ **Fix**: Verify certificates exist

```bash
ls -lh /opt/riva/certs/
# Should show server.crt and server.key
```

## Project Structure

```
transcription-realtime-whisper/
├── scripts/              # Deployment automation
│   ├── 005-040/         # Initial setup
│   ├── 100-165/         # NVIDIA Riva deployment
│   ├── 200-220/         # Operations (shutdown/startup)
│   └── 300-320/         # WhisperLive edge proxy
├── site/                # Browser clients
│   ├── index.html       # Main WhisperLive UI
│   └── test-whisper.html # Simple test client
├── src/                 # Source code
│   └── asr/            # Riva WebSocket bridge
├── audio-api/          # Backend S3 audio storage API
├── docs/               # Additional documentation
└── *.md                # Comprehensive documentation

```

## Requirements

### AWS Resources

- EC2 instances (GPU: g4dn.xlarge, Edge: t3.medium)
- VPC with internet gateway
- Security groups
- S3 bucket (for Riva model cache)

### Software

- Ubuntu 22.04 LTS
- Docker and Docker Compose
- Python 3.10+
- NVIDIA drivers (on GPU instance)
- CUDA 12.x (for GPU acceleration)

## License

MIT License - See LICENSE file for details

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## Support

For issues and questions:

1. Check documentation (COMPLETE_DEPLOYMENT_GUIDE.md)
2. Review troubleshooting sections
3. Check logs:
   - Edge: `docker compose logs -f`
   - GPU WhisperLive: `sudo journalctl -u whisperlive -f`
   - GPU Riva: `docker logs riva-server -f`
4. Open GitHub issue with logs and error details

## Acknowledgments

- **NVIDIA Riva** - Enterprise speech AI platform
- **Collabora WhisperLive** - Open-source Whisper streaming
- **OpenAI Whisper** - Foundation models
- **faster-whisper** - CUDA-accelerated Whisper inference

## What You Get

A production-ready real-time speech recognition system with:

- ✅ Secure HTTPS/WSS browser access
- ✅ Private GPU instance (not publicly exposed)
- ✅ Multiple ASR backend options (Riva or WhisperLive)
- ✅ Real-time streaming transcription
- ✅ Multiple language support
- ✅ Automated deployment scripts
- ✅ Comprehensive documentation
- ✅ Cost-optimized architecture
- ✅ Browser-based UI
- ✅ Production-grade security

**Start transcribing in 20 minutes!** 🎤✨

---

*For detailed deployment instructions, see [COMPLETE_DEPLOYMENT_GUIDE.md](COMPLETE_DEPLOYMENT_GUIDE.md)*
