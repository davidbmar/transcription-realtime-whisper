# Hybrid Dual-Path Transcription Demo Guide

## What It Does

The hybrid demo combines **two transcription paths** in real-time:

1. **Path 1 (Real-time)**: Audio → WebSocket → Riva → Live transcription
2. **Path 2 (Storage)**: Audio → WebM chunks → S3 → Batch processing later

**Single audio capture, dual processing!**

---

## Prerequisites

✅ **Backend audio-api deployed** (completed)
- API Endpoint: `https://1avw7l3k1b.execute-api.us-east-2.amazonaws.com`
- All 5 Lambda functions working
- Cognito authentication enabled

✅ **Riva WebSocket bridge running** (needs verification)
- Port 8443 for WebSocket (Riva)
- Port 8444 for HTTPS demo server

---

## Step 1: Check WebSocket Bridge Status

```bash
# Check if the WebSocket bridge service is running
sudo systemctl status riva-websocket-bridge
```

**If not running:**
```bash
# Start the service
sudo systemctl start riva-websocket-bridge

# Check logs
sudo journalctl -u riva-websocket-bridge -f
```

---

## Step 2: Check GPU Instance (Riva)

```bash
# Check if GPU instance is running
aws ec2 describe-instances \
  --instance-ids i-XXXXXXXXX \
  --query 'Reservations[0].Instances[0].State.Name' \
  --region us-east-2
```

**If stopped, start it:**
```bash
cd ~/event-b/nvidia-riva-conformer-streaming-ver-9-and-audio-ui-cf-s3-lambda-cognito-interface
./scripts/210-startup-restore.sh
```

---

## Step 3: Access the Hybrid Demo

Open your browser to:
```
https://<BUILD_BOX_IP>:8444/hybrid-demo.html
```

**Or if on the build box:**
```
https://3.16.124.227:8444/hybrid-demo.html
```

**Note:** You'll get an SSL warning (self-signed cert) - click "Advanced" → "Proceed anyway"

---

## Step 4: Test the Dual-Path System

### 4.1 Authenticate

1. Enter Cognito credentials:
   - **Email**: `dmar@capsule.com`
   - **Password**: (your password)
2. Click **"Login"**
3. Wait for green "Authenticated" confirmation

### 4.2 Start Recording

1. Click **"Start Recording"**
2. Browser will ask for microphone permission - click **"Allow"**
3. Watch the status dashboard:
   - **WebSocket (Riva)**: Should show "Transcribing"
   - **S3 Upload**: Should show "Uploading 1..." then "2..." etc.
   - **Session**: Shows your session ID
   - **Chunks Uploaded**: Counts uploaded chunks

### 4.3 Speak

Say something like:
```
"Hello, this is a test of the dual-path transcription system.
 The audio is being sent to both Riva for real-time transcription
 and to S3 for batch processing later."
```

You should see:
- **Live transcription** appearing in real-time (from Riva)
- **Chunk counter** incrementing every 5 seconds
- **Debug log** showing upload progress

### 4.4 Stop Recording

1. Click **"Stop Recording"**
2. System will:
   - Stop MediaRecorder
   - Disconnect WebSocket
   - Finalize S3 session
   - Upload manifest.json

---

## Step 5: Verify S3 Storage

Check that chunks were uploaded:

```bash
aws s3 ls s3://dbm-test-1100-13-2025/users/ --recursive | grep $(date +%Y-%m-%d)
```

Expected output:
```
2025-10-15 04:30:12     102400 users/617b.../audio/sessions/session-xxx/chunks/00001-000000-005000.webm
2025-10-15 04:30:17     105600 users/617b.../audio/sessions/session-xxx/chunks/00002-005000-010000.webm
2025-10-15 04:30:22       1234 users/617b.../audio/sessions/session-xxx/manifest.json
```

---

## Architecture

```
┌─────────────────┐
│   Browser       │
│  (Microphone)   │
└────────┬────────┘
         │ Audio Stream
         │
    ┌────▼────────────┐
    │ MediaRecorder   │
    │  (1 capture)    │
    └────┬────────────┘
         │
    ┌────▼─────┬────────────────┐
    │          │                │
┌───▼───┐  ┌──▼──────┐   ┌────▼─────┐
│ PCM16 │  │  WebM   │   │  WebM    │
│ Stream│  │ Chunk 1 │   │ Chunk 2  │
└───┬───┘  └────┬────┘   └────┬─────┘
    │           │              │
    │      ┌────▼──────────────▼─────┐
    │      │ S3 Upload (audio-api)   │
    │      │ - Presign                │
    │      │ - Upload                 │
    │      │ - Complete               │
    │      │ - Manifest               │
    │      └─────────┬────────────────┘
    │                │
┌───▼──────────┐    │
│ WebSocket    │    │
│ (port 8443)  │    │
└───┬──────────┘    │
    │               │
┌───▼──────────┐    │
│ Riva gRPC    │    │
│ Conformer-CTC│    │
└───┬──────────┘    │
    │               │
┌───▼──────────┐ ┌──▼──────────────┐
│ Real-time    │ │ S3 Storage      │
│ Transcription│ │ dbm-test-1100-  │
│ (immediate)  │ │ 13-2025         │
└──────────────┘ └─────────────────┘
```

---

## Troubleshooting

### "WebSocket connection failed"

**Check:**
1. Is WebSocket bridge running?
   ```bash
   sudo systemctl status riva-websocket-bridge
   ```
2. Is port 8443 open in security group?
3. Is GPU instance running with Riva?
   ```bash
   ssh -i ~/.ssh/dbm-sep23-2025.pem ubuntu@<GPU_IP> 'curl http://localhost:8000/v2/health/ready'
   ```

### "Authentication failed"

**Check:**
1. Cognito credentials correct?
2. USER_PASSWORD_AUTH flow enabled? (already done via enablePasswordAuth.sh)
3. Check browser console for error details

### "S3 upload failed"

**Check:**
1. ID token valid? (tokens expire after 1 hour)
2. Lambda has S3 permissions?
3. Check CloudWatch logs:
   ```bash
   aws logs tail /aws/lambda/audio-api-dev-presignChunk --since 5m --region us-east-2
   ```

### "No transcription appearing"

**Check:**
1. Microphone permission granted in browser?
2. WebSocket connected? (check status indicator)
3. Check WebSocket bridge logs:
   ```bash
   sudo journalctl -u riva-websocket-bridge -f
   ```

---

## What Happens After Recording

After you stop recording, you have:

1. **Real-time transcription** - Already displayed (ephemeral)
2. **Audio chunks in S3** - Permanent storage
3. **Manifest.json** - Metadata linking chunks to timestamps

**Next steps:**
- Run Whisper batch processing on stored chunks
- Compare Riva (real-time) vs Whisper (batch) accuracy
- Build search/retrieval system over transcriptions
- Archive long-term audio for compliance

---

## File Locations

**Frontend:**
- `static/hybrid-demo.html` - Main hybrid demo
- `static/riva-websocket-client.js` - WebSocket client library

**Backend:**
- `audio-api/` - Lambda functions (deployed)
- `src/asr/riva_websocket_bridge.py` - WebSocket bridge

**Configuration:**
- `audio-api/.env` - API configuration
- `.env` - Riva configuration

---

## Success Criteria

✅ You should see:
1. **Green "Authenticated" status** after login
2. **"WebSocket (Riva): Transcribing"** when recording
3. **"Chunks Uploaded: 1, 2, 3..."** incrementing every 5s
4. **Live transcription text** appearing as you speak
5. **"Session finalized"** in log after stopping
6. **Files in S3** when you check with aws s3 ls

---

## Next Steps

1. **Test end-to-end** with this hybrid demo
2. **Implement batch processing** (EventBridge → Lambda → Whisper)
3. **Build search UI** for querying transcriptions
4. **Add speaker diarization** (who said what)
5. **Implement resume/retry** for failed chunk uploads

---

## Support

- **WebSocket Issues**: Check `src/asr/riva_websocket_bridge.py`
- **API Issues**: Check `audio-api/src/handlers/`
- **Riva Issues**: Check `docs/CONFORMER_CTC_STREAMING_GUIDE.md`
- **Architecture**: Check `INTEGRATION_ANALYSIS.md`
