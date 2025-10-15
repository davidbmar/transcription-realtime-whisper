# Next Session Instructions - Hybrid Dual-Path Transcription

**Date:** 2025-10-15
**Project:** nvidia-riva-conformer-streaming-ver-9-and-audio-ui-cf-s3-lambda-cognito-interface
**Working Directory:** `/home/ubuntu/event-b/nvidia-riva-conformer-streaming-ver-9-and-audio-ui-cf-s3-lambda-cognito-interface`

---

## Current Status - What Works ✅

### 1. Backend S3 Writer API (audio-api) - FULLY WORKING
- **Deployed to AWS Lambda:** All 5 functions working
- **API Endpoint:** `https://1avw7l3k1b.execute-api.us-east-2.amazonaws.com`
- **Authentication:** Cognito (USER_PASSWORD_AUTH enabled)
- **S3 Bucket:** `dbm-test-1100-13-2025`
- **Test User:** dmar@capsule.com
- **Tested:** All endpoints (create session, presign chunk, upload, complete, finalize) - ✅ WORKING

### 2. Audio Chunk Recording - FULLY WORKING
- **Pattern:** Stop/restart MediaRecorder (from audio-ui project)
- **Timer:** 1-second interval with modulo check
- **Result:** ALL chunks are independently playable (not just first one!)
- **Tested with:** `test-audio-only.html` - ✅ ALL CHUNKS PLAYABLE

### 3. Hybrid Dual-Path Demo - WORKING (S3 path only)
- **File:** `hybrid-demo-v4.html`
- **Access:** `https://3.16.124.227:8444/hybrid-demo-v4.html`
- **S3 Upload Path:** ✅ WORKING - all chunks playable
- **WebSocket Transcription Path:** ❌ NOT WORKING - needs GPU startup

### Key Fix Applied
- **Problem:** V3 created TWO separate microphone streams (MediaRecorder + WebSocket) causing interference
- **Solution:** V4 uses AudioContext.createMediaStreamDestination() to split ONE stream
- **Result:** S3 chunks are now ALL playable!

---

## What Doesn't Work Yet ❌

### Riva Real-time Transcription (WebSocket Path)
- **Reason:** GPU worker not running
- **Status:** WebSocket bridge code ready, but needs:
  1. GPU instance started
  2. Riva Conformer-CTC model running on GPU
  3. WebSocket bridge service running on build box (port 8443)

---

## How to Start Riva Transcription (For Tomorrow)

### Step 1: Start GPU Instance
```bash
cd /opt/riva/nvidia-riva-conformer-streaming-ver-8

# Check current GPU status
aws ec2 describe-instances --instance-ids i-04eb48e769bbc122b --region us-east-2 --query 'Reservations[0].Instances[0].State.Name'

# If stopped, start it
aws ec2 start-instances --instance-ids i-04eb48e769bbc122b --region us-east-2

# Wait for it to come up (~2 minutes)
aws ec2 wait instance-running --instance-ids i-04eb48e769bbc122b --region us-east-2

# Get new IP address (changes on restart)
NEW_IP=$(aws ec2 describe-instances --instance-ids i-04eb48e769bbc122b --region us-east-2 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "New GPU IP: $NEW_IP"

# Update .env file
sed -i "s/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=$NEW_IP/" .env
```

### Step 2: Verify Riva is Running on GPU
```bash
# SSH to GPU and check Riva container
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@$NEW_IP 'docker ps | grep riva'

# Check Riva health
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@$NEW_IP 'curl -s http://localhost:8000/v2/health/ready'

# If Riva is NOT running, start it
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@$NEW_IP 'cd /opt/riva && docker-compose up -d'

# Wait 1-2 minutes for Riva to load model
sleep 120

# Verify again
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@$NEW_IP 'curl -s http://localhost:8000/v2/health/ready'
# Should return: {"ready":true}
```

### Step 3: Start WebSocket Bridge on Build Box
```bash
# Check if WebSocket bridge service is running
sudo systemctl status riva-websocket-bridge

# If not running, start it
sudo systemctl start riva-websocket-bridge

# Check logs
sudo journalctl -u riva-websocket-bridge -f

# Should see:
# - "Starting Riva WebSocket Bridge..."
# - "WebSocket server listening on 0.0.0.0:8443"
# - "Connected to Riva gRPC server at 18.117.113.139:50051"
```

### Step 4: Test Complete Dual-Path System
```bash
# 1. Open browser to hybrid-demo-v4.html
# https://3.16.124.227:8444/hybrid-demo-v4.html

# 2. Login with Cognito credentials
# Username: dmar@capsule.com

# 3. Click "Start Recording"
# - Should see "WebSocket (Riva): Connected"
# - Should see "WebSocket (Riva): Transcribing"
# - Should see "S3 Upload: Ready"

# 4. Speak for 15+ seconds (at least 3 chunks)
# - Watch transcription appear in real-time (from Riva)
# - Watch chunk count increment (to S3)

# 5. Click "Stop Recording"
# - Check logs for "Session finalized"

# 6. Verify BOTH paths worked:

# Path 1: Real-time transcription (should see in browser UI)
# - Transcription text displayed during recording

# Path 2: S3 chunks (download and test playback)
aws s3 ls s3://dbm-test-1100-13-2025/users/{USER_ID}/audio/sessions/ --recursive

# Download chunks
aws s3 cp s3://dbm-test-1100-13-2025/users/{USER_ID}/audio/sessions/{SESSION_ID}/chunks/00001-*.webm ./chunk1.webm
aws s3 cp s3://dbm-test-1100-13-2025/users/{USER_ID}/audio/sessions/{SESSION_ID}/chunks/00002-*.webm ./chunk2.webm
aws s3 cp s3://dbm-test-1100-13-2025/users/{USER_ID}/audio/sessions/{SESSION_ID}/chunks/00003-*.webm ./chunk3.webm

# Test playback - ALL should play!
ffplay chunk1.webm
ffplay chunk2.webm  # ← Should work!
ffplay chunk3.webm  # ← Should work!
```

---

## Architecture Summary

```
Browser (mic) → Single MediaStream
    ↓
    ├─→ AudioContext.createMediaStreamDestination() → MediaRecorder
    │   └─→ Stop/restart every 5 seconds
    │       └─→ Presigned S3 upload
    │           └─→ S3: users/{userId}/audio/sessions/{sessionId}/chunks/
    │
    └─→ RivaWebSocketClient
        └─→ WebSocket:8443 (build box)
            └─→ gRPC:50051 (GPU worker)
                └─→ Riva Conformer-CTC streaming ASR
                    └─→ Real-time transcription results
```

---

## Key Files

### Working Demo
- **Main:** `/opt/riva/nvidia-riva-conformer-streaming-ver-8/static/hybrid-demo-v4.html`
- **Test:** `/opt/riva/nvidia-riva-conformer-streaming-ver-8/static/test-audio-only.html`
- **Access:** `https://3.16.124.227:8444/hybrid-demo-v4.html`

### Backend API
- **Location:** `~/event-b/nvidia-riva-conformer-streaming-ver-9-and-audio-ui-cf-s3-lambda-cognito-interface/audio-api/`
- **Deployed:** All 5 Lambda functions
- **Endpoint:** `https://1avw7l3k1b.execute-api.us-east-2.amazonaws.com`

### WebSocket Bridge
- **Service:** `riva-websocket-bridge` (systemd)
- **Port:** 8443
- **Source:** `/opt/riva/nvidia-riva-conformer-streaming-ver-8/src/asr/`

### Documentation
- **Pattern Comparison:** `MEDIARECORDER_PATTERN_COMPARISON.md`
- **This File:** `NEXT_SESSION_INSTRUCTIONS.md`
- **Project README:** `CLAUDE.md`

---

## GPU Configuration

### Instance Details
- **Instance ID:** `i-04eb48e769bbc122b`
- **Instance Type:** `g4dn.xlarge` (NVIDIA T4 GPU)
- **Region:** `us-east-2`
- **Last Known IP:** `18.117.113.139` (changes on restart!)
- **SSH Key:** `~/.ssh/dbm-sep23-2025.pem`

### Riva Configuration
- **Model:** Conformer-CTC-XL streaming
- **gRPC Port:** 50051
- **Health Port:** 8000
- **Docker:** riva-server container
- **Model Path:** `/opt/riva/models_conformer_ctc_streaming`

### Cost Warning
- **Hourly Cost:** ~$0.526/hour when running
- **Remember to shut down GPU when done!**
- **Shutdown:** `aws ec2 stop-instances --instance-ids i-04eb48e769bbc122b --region us-east-2`

---

## Troubleshooting

### If WebSocket won't connect:
```bash
# 1. Check GPU IP is correct in .env
cat /opt/riva/nvidia-riva-conformer-streaming-ver-8/.env | grep GPU_INSTANCE_IP

# 2. Verify Riva is healthy
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@18.117.113.139 'curl -s http://localhost:8000/v2/health/ready'

# 3. Check WebSocket bridge logs
sudo journalctl -u riva-websocket-bridge -n 50

# 4. Restart WebSocket bridge
sudo systemctl restart riva-websocket-bridge
```

### If chunks are not playable:
- Should NOT happen anymore (fixed in V4)
- If it does, check that you're using `hybrid-demo-v4.html` (NOT v3)
- Check browser console for MediaRecorder errors

### If S3 upload fails:
```bash
# Check Lambda function logs
aws logs tail /aws/lambda/audio-api-dev-presignChunk --follow --region us-east-2

# Verify Cognito token is valid (login again)
```

---

## What We Fixed Today

### MediaRecorder Chunk Playback Issue
**Problem:** Only first chunk was playable, chunks 2, 3, 4... failed

**Root Cause Investigation:**
1. V1 (hybrid-demo.html): Used `mediaRecorder.start(5000)` with timeslice → Only first chunk playable
2. V2 (hybrid-demo-fixed.html): Used setTimeout per chunk → User said didn't work
3. V3 (hybrid-demo-v3.html): Copied EXACT audio-ui setInterval pattern → User said didn't work
4. Created test-audio-only.html (NO WebSocket) → All chunks playable! ✅

**Conclusion:** MediaRecorder pattern was correct. Problem was dual stream interference.

**Final Fix (V4):**
- Single microphone stream
- AudioContext.createMediaStreamDestination() to split stream
- MediaRecorder uses split stream (isolated from WebSocket)
- **Result:** All chunks playable! ✅

### Pattern Details
```javascript
// Get ONE microphone stream
this.mediaStream = await navigator.mediaDevices.getUserMedia({audio: {...}});

// Split via AudioContext
this.audioContext = new AudioContext({ sampleRate: 48000 });
const source = this.audioContext.createMediaStreamSource(this.mediaStream);
this.mediaStreamDestination = this.audioContext.createMediaStreamDestination();
source.connect(this.mediaStreamDestination);

// MediaRecorder uses SPLIT stream
this.mediaRecorder = new MediaRecorder(this.mediaStreamDestination.stream, options);

// WebSocket uses ORIGINAL stream (creates its own AudioContext internally)
await this.wsClient.startTranscription();
```

---

## Next Steps (For Tomorrow or Future Sessions)

1. **Start GPU and verify Riva** (steps above)
2. **Start WebSocket bridge** (steps above)
3. **Test dual-path transcription** with hybrid-demo-v4.html
4. **Verify both paths:**
   - Real-time transcription displayed in UI
   - All S3 chunks are playable
5. **(Optional) Build batch processing pipeline:**
   - EventBridge trigger on S3 upload
   - Lambda function to process chunks
   - Whisper API for batch transcription
   - Compare Riva (real-time) vs Whisper (batch) accuracy
6. **Remember to shutdown GPU when done!**

---

## Important Notes for Next Claude Session

- **DO NOT modify** audio-ui or nvidia-riva-conformer-streaming-ver-8 source directories
- **ONLY work in:** `~/event-b/nvidia-riva-conformer-streaming-ver-9-and-audio-ui-cf-s3-lambda-cognito-interface`
- **S3 path works perfectly** - all chunks independently playable
- **WebSocket path ready** - just needs GPU startup
- **Cost awareness:** GPU is ~$0.526/hour - don't leave running overnight

---

## Quick Start Commands (Copy-Paste Tomorrow)

```bash
# Change to project directory
cd /opt/riva/nvidia-riva-conformer-streaming-ver-8

# Start GPU
aws ec2 start-instances --instance-ids i-04eb48e769bbc122b --region us-east-2
aws ec2 wait instance-running --instance-ids i-04eb48e769bbc122b --region us-east-2

# Get new IP
NEW_IP=$(aws ec2 describe-instances --instance-ids i-04eb48e769bbc122b --region us-east-2 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "GPU IP: $NEW_IP"

# Update .env
sed -i "s/^GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=$NEW_IP/" .env

# Wait for Riva to be ready (2-3 minutes)
sleep 180

# Check Riva health
ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@$NEW_IP 'curl -s http://localhost:8000/v2/health/ready'

# Start WebSocket bridge
sudo systemctl restart riva-websocket-bridge

# Check bridge logs
sudo journalctl -u riva-websocket-bridge -n 20

# Open browser
echo "Ready! Open: https://3.16.124.227:8444/hybrid-demo-v4.html"
```

---

## Success Criteria

✅ **S3 Path Working:**
- Login with Cognito ✅
- Record audio ✅
- Chunks uploaded to S3 ✅
- All chunks independently playable ✅

❌ **WebSocket Path (Needs GPU):**
- WebSocket connects to bridge
- Real-time transcription appears in UI
- Transcription is accurate

**When Both Work:**
- Single recording session produces BOTH:
  1. Real-time transcription (for immediate user feedback)
  2. Playable audio chunks in S3 (for batch processing/archival)
