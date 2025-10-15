# Integration Analysis: Audio UI + Riva Streaming
## Two-Pass Transcription Architecture

**Date:** 2025-10-15
**Source Repositories:**
- `audio-ui-cf-s3-lambda-cognito` - Web-based audio recording with S3 storage
- `nvidia-riva-conformer-streaming-ver-8` - Real-time streaming ASR with Riva

---

## Executive Summary

This document analyzes the integration of two systems to create a **dual-path audio processing pipeline**:

1. **Real-time Path**: Browser → WebSocket → Riva GPU → Immediate transcription
2. **Storage Path**: Browser → API Gateway → Lambda → S3 → Batch processing

The goal is to combine the immediate feedback of streaming ASR with the reliability and quality of batch processing on stored audio.

---

## Current System 1: audio-ui-cf-s3-lambda-cognito

### Architecture Overview
```
┌─────────────┐    HTTPS/REST     ┌──────────────┐
│   Browser   │◄─────────────────►│  CloudFront  │
│  (React)    │   Cognito Auth    │              │
│             │                   │  API Gateway │
└─────────────┘                   │   + Lambda   │
                                  └──────────────┘
                                         │
                                         ▼
                                  ┌──────────────┐
                                  │      S3      │
                                  │ Presigned    │
                                  │   URLs       │
                                  └──────────────┘
```

### Components

#### Backend (AWS Lambda + API Gateway)

**File: `api/audio.js`** - Audio Recording API
- `uploadChunk()` - Generate presigned S3 URL for audio chunk
  - Input: `{sessionId, chunkNumber, contentType, duration}`
  - Output: `{uploadUrl, s3Key, expiresIn: 300}`
  - S3 Key Pattern: `users/{userId}/audio/sessions/{date}-{sessionId}/chunk-{num}.webm`

- `updateSessionMetadata()` - Store session metadata
  - Input: `{sessionId, metadata}`
  - Stores: `users/{userId}/audio/sessions/{date}-{sessionId}/metadata.json`
  - Metadata includes: duration, chunkCount, status, transcriptionStatus, keywords, conversationContext

- `listSessions()` - List user's audio sessions
  - Returns: Array of sessions with metadata

- `getFailedChunks()` - Get missing chunks for retry
  - Compares expected chunks vs actual S3 objects

- `deleteChunk()` - Delete audio chunk from S3

**File: `api/s3.js`** - General File Operations
- `listObjects()` - List S3 objects (user-scoped)
- `getDownloadUrl()` - Generate presigned download URL
- `getUploadUrl()` - Generate presigned upload URL
- `deleteObject()` - Delete file
- `renameObject()` - Rename file (copy + delete)
- `moveObject()` - Move file to different path

**File: `api/handler.js`** - Auth Test Endpoint
- `getData()` - Simple authenticated endpoint for testing

**File: `api/memory.js`** - Memory Storage
- `storeMemory()` - Store Claude memory data
- `storeMemoryPublic()` - Public memory endpoint

#### Frontend (React + Cognito)

**File: `web/audio.html`** - Audio Recording UI
- React-based single-page application
- Uses MediaRecorder API for audio capture
- **Recording Flow:**
  1. Generate session ID
  2. Request microphone access
  3. Start MediaRecorder with configurable chunk duration (5s-5min)
  4. On chunk completion:
     - Request presigned URL from Lambda
     - Upload chunk directly to S3
     - Update local UI with upload status
  5. Store chunk metadata and playback URLs

- **Key Features:**
  - Real-time upload status (uploading, synced, failed)
  - Local playback of recorded chunks
  - Session management
  - Mobile-optimized UI

- **Audio Format:**
  - WebM/Opus (preferred)
  - 48kHz sample rate
  - Configurable chunk duration

**File: `web/index.html`** - File Manager Dashboard
- Lists user files from S3
- Upload/download/delete operations
- Folder navigation

**File: `web/app.js`** - Main Application Logic
- Cognito authentication
- JWT token management
- API request wrapper

#### Infrastructure (Serverless Framework)

**File: `serverless.yml`** - AWS Infrastructure
- **Cognito:**
  - User Pool for authentication
  - Identity Pool for AWS credentials
  - User Pool Client with OAuth flows

- **S3:**
  - Bucket: `dbm-test-1100-13-2025`
  - User-scoped prefixes: `users/{userId}/`
  - Audio storage: `users/{userId}/audio/sessions/{date}-{sessionId}/`
  - CORS enabled for presigned URL uploads

- **API Gateway:**
  - REST API with Cognito authorizer
  - Endpoints: `/api/data`, `/api/s3/*`, `/api/audio/*`, `/api/memory`

- **CloudFront:**
  - CDN for static content (S3 origin)
  - API proxy (API Gateway origin)
  - Cache behaviors for `/api/*` paths

- **IAM:**
  - Lambda execution roles
  - S3 permissions (user-scoped)
  - Cognito identity pool roles

### API Endpoints Summary

| Endpoint | Method | Purpose | Auth |
|----------|--------|---------|------|
| `/api/data` | GET | Auth test | Required |
| `/api/s3/list` | GET | List user files | Required |
| `/api/s3/download/{key}` | GET | Download URL | Required |
| `/api/s3/upload` | POST | Upload URL | Required |
| `/api/s3/delete/{key}` | DELETE | Delete file | Required |
| `/api/s3/rename` | POST | Rename file | Required |
| `/api/s3/move` | POST | Move file | Required |
| `/api/audio/upload-chunk` | POST | Get chunk upload URL | Required |
| `/api/audio/session-metadata` | POST | Update metadata | Required |
| `/api/audio/sessions` | GET | List sessions | Required |
| `/api/audio/failed-chunks` | GET | Get failed chunks | Required |
| `/api/audio/delete-chunk` | DELETE | Delete chunk | Required |
| `/api/memory` | POST | Store memory | Required |
| `/api/memory/public` | POST | Store memory (public) | None |

### Key Design Patterns

1. **User Isolation:** All S3 keys prefixed with `users/{userId}/`
2. **Presigned URLs:** Browser uploads/downloads directly to/from S3
3. **Chunked Upload:** Audio split into configurable chunks (5s-5min)
4. **Template System:** Web files use `.template` files with env var substitution
5. **Session Organization:** Audio organized by date and session ID

---

## Current System 2: nvidia-riva-conformer-streaming-ver-8

### Architecture Overview
```
┌─────────────┐    WSS (8443)    ┌──────────────┐    gRPC (50051)   ┌──────────────┐
│   Browser   │◄────────────────►│  Build Box   │◄─────────────────►│  GPU Worker  │
│  (Audio)    │   PCM16 Audio    │  WebSocket   │   Audio Stream    │  RIVA 2.19   │
│             │                  │   Bridge     │                   │  Conformer   │
└─────────────┘                  │   :8443      │                   │   CTC-XL     │
                                 │   :8444 Demo │                   │   :50051     │
                                 └──────────────┘                   └──────────────┘
```

### Components

#### Backend (Python WebSocket Bridge)

**File: `src/asr/riva_websocket_bridge.py`** - WebSocket ↔ gRPC Bridge
- WebSocket server on port 8443 (WSS)
- Bridges browser audio to Riva gRPC endpoint
- **Flow:**
  1. Browser connects via WebSocket
  2. Bridge creates gRPC streaming connection to Riva
  3. Browser sends PCM16 audio chunks (binary)
  4. Bridge forwards to Riva gRPC StreamingRecognize
  5. Riva returns partial/final transcriptions
  6. Bridge sends JSON responses to browser

- **Message Protocol:**
  - Client → Server: Binary PCM16 audio OR JSON control messages
  - Server → Client: JSON transcription results

- **Configuration:**
  - Loads from `.env` file
  - SSL/TLS enabled (self-signed certs at `/opt/riva/certs/`)
  - Runs as systemd service: `riva-websocket-bridge`

**File: `src/asr/riva_client.py`** - Riva gRPC Client Wrapper
- Wraps Riva StreamingRecognize gRPC calls
- Manages audio streaming to Riva
- Handles partial and final transcription results

#### Frontend (Vanilla JS)

**File: `static/index.html`** - Demo UI
- Simple real-time transcription interface
- **Flow:**
  1. Connect to WebSocket
  2. Request microphone access
  3. Capture audio with AudioWorklet or ScriptProcessor
  4. Resample to 16kHz mono PCM16
  5. Send audio chunks to WebSocket
  6. Display transcriptions

**File: `static/websocket-client.js`** - WebSocket Client
- Manages WebSocket connection
- Sends audio data (binary)
- Receives transcription responses (JSON)
- Auto-reconnect logic

**File: `static/audio-recorder.js`** - Audio Recording
- Uses Web Audio API
- Resamples to 16kHz mono
- Converts float32 to int16 (PCM16)
- Sends chunks every 100ms (1600 samples)

**File: `static/transcription-ui.js`** - UI Updates
- Displays partial transcriptions
- Displays final transcriptions
- Shows audio level visualization
- Metrics display

#### Infrastructure (GPU Worker + Build Box)

**GPU Worker (AWS g4dn.xlarge):**
- NVIDIA Tesla T4 GPU
- NVIDIA Riva 2.19 Docker container
- Conformer-CTC-XL streaming model
- **Model Parameters:**
  - `ms_per_timestep=40` (NOT 80!)
  - `chunk_size=0.16` (160ms)
  - `padding_size=1.92` (1920ms)
  - `streaming=true`

- **Endpoints:**
  - `:50051` - gRPC StreamingRecognize
  - `:8000` - HTTP health check

**Build Box:**
- WebSocket bridge (port 8443)
- HTTPS demo server (port 8444)
- Python 3.8+
- SSL certificates at `/opt/riva/certs/`

### WebSocket Protocol

**Client → Server (Audio Data):**
```javascript
// Binary PCM16 audio chunks
ws.send(pcm16AudioBuffer);
```

**Client → Server (Control Messages):**
```json
{
  "type": "start_recording",
  "config": {
    "sample_rate": 16000,
    "encoding": "pcm16"
  }
}
```

**Server → Client (Transcription):**
```json
{
  "type": "transcription",
  "text": "Hello world",
  "words": [
    {
      "word": "Hello",
      "start": 0.0,
      "end": 0.5,
      "confidence": 0.95
    }
  ],
  "is_final": true,
  "processing_time_ms": 45
}
```

### Key Design Patterns

1. **Streaming ASR:** Continuous audio → immediate transcription
2. **WebSocket Bridge:** Browser ↔ gRPC translation layer
3. **PCM16 Format:** 16kHz mono int16 audio
4. **Systemd Services:** Auto-start on boot
5. **Cost Optimization:** Shutdown/startup scripts for GPU

---

## Integration Strategy: Hybrid Two-Pass System

### Unified Architecture
```
                          ┌─────────────────────────────────────────┐
                          │          Browser Client                 │
                          │    (React Audio Recorder + WSS)         │
                          └─────────────────────────────────────────┘
                                    │                    │
                   ┌────────────────┘                    └────────────────┐
                   │                                                      │
           ┌───────▼────────┐                                   ┌────────▼────────┐
           │  Path 1: LIVE  │                                   │ Path 2: STORAGE │
           │  Real-time ASR │                                   │  Chunk Upload   │
           └───────┬────────┘                                   └────────┬────────┘
                   │                                                     │
        WSS :8443  │                                          HTTPS/REST │
                   │                                                     │
           ┌───────▼─────────┐                              ┌───────────▼─────────┐
           │  WebSocket      │                              │  CloudFront         │
           │  Bridge         │                              │  + API Gateway      │
           │  (Build Box)    │                              │  + Lambda           │
           └───────┬─────────┘                              └───────────┬─────────┘
                   │                                                     │
         gRPC      │                                          Presigned  │
         :50051    │                                          URLs       │
                   │                                                     │
           ┌───────▼─────────┐                              ┌───────────▼─────────┐
           │  NVIDIA Riva    │                              │      S3 Bucket      │
           │  Conformer-CTC  │                              │  Audio Chunks +     │
           │  (GPU Worker)   │                              │  Metadata           │
           └─────────────────┘                              └─────────────────────┘
                   │                                                     │
                   │                                                     │
                   ▼                                                     ▼
           ┌─────────────────┐                              ┌─────────────────────┐
           │  Immediate      │                              │  Batch Processing   │
           │  Transcription  │                              │  (Future: Whisper,  │
           │  to UI          │                              │   Speaker ID, etc)  │
           └─────────────────┘                              └─────────────────────┘
```

### Component Mapping

| Component | Source System | Role in Integration |
|-----------|---------------|---------------------|
| **Browser Audio Capture** | System 2 (Riva) | Reuse audio-recorder.js for 16kHz PCM16 |
| **WebSocket Client** | System 2 (Riva) | Handle real-time ASR streaming |
| **HTTP API Client** | System 1 (Audio UI) | Handle S3 chunk uploads |
| **React UI** | System 1 (Audio UI) | Main application framework |
| **Cognito Auth** | System 1 (Audio UI) | User authentication |
| **WebSocket Bridge** | System 2 (Riva) | Real-time ASR path |
| **Lambda Functions** | System 1 (Audio UI) | Storage path API |
| **S3 Storage** | System 1 (Audio UI) | Audio archive |

### Proposed Integration Points

#### 1. Unified Frontend

**New File: `web/hybrid-recorder.html`** (merge of both UIs)

**Features:**
- React-based UI (from System 1)
- Cognito authentication (from System 1)
- **Dual audio capture:**
  - Path 1: Stream to WebSocket for real-time ASR
  - Path 2: Record chunks for S3 upload

**Audio Pipeline:**
```javascript
// Single MediaRecorder with dual outputs
const mediaRecorder = new MediaRecorder(stream, {
  mimeType: 'audio/webm;codecs=opus',
  audioBitsPerSecond: 128000
});

mediaRecorder.ondataavailable = async (event) => {
  const audioBlob = event.data;

  // Path 1: Convert to PCM16 and stream to WebSocket
  const pcm16 = await convertToPCM16(audioBlob);
  websocket.send(pcm16);

  // Path 2: Upload WebM chunk to S3 via presigned URL
  const uploadUrl = await getPresignedUrl(sessionId, chunkNumber);
  await fetch(uploadUrl, {
    method: 'PUT',
    body: audioBlob,
    headers: { 'Content-Type': 'audio/webm' }
  });
};
```

#### 2. Backend APIs

**Existing Lambda Functions (Keep):**
- `api/audio.js` - All existing endpoints
- `api/s3.js` - All existing endpoints
- `api/handler.js` - Auth test
- `api/memory.js` - Memory storage

**New Lambda Function:**
```javascript
// api/transcription.js - Transcription management
module.exports.linkTranscription = async (event) => {
  // Link real-time ASR results to stored audio chunks
  const { sessionId, chunkNumber, transcription } = JSON.parse(event.body);

  // Store transcription metadata alongside audio chunk
  const metadataKey = `users/{userId}/audio/sessions/{sessionId}/transcriptions/chunk-{chunkNumber}.json`;

  await s3.putObject({
    Bucket: bucketName,
    Key: metadataKey,
    Body: JSON.stringify({
      chunkNumber,
      transcription,
      timestamp: new Date().toISOString(),
      source: 'riva-streaming'
    })
  }).promise();

  return { statusCode: 200, body: JSON.stringify({ success: true }) };
};
```

**WebSocket Bridge (Keep):**
- `src/asr/riva_websocket_bridge.py` - No changes needed
- Run as systemd service on build box

#### 3. S3 Storage Structure

**Enhanced S3 Key Pattern:**
```
users/{userId}/audio/sessions/{date}-{sessionId}/
  ├─ chunks/
  │  ├─ 001-00000-05000.webm         # 5-second WebM chunks
  │  ├─ 002-05000-10000.webm
  │  └─ ...
  ├─ transcriptions/
  │  ├─ chunk-001.json               # Riva streaming results
  │  ├─ chunk-002.json
  │  └─ final-whisper.json           # Future: Batch Whisper results
  ├─ manifest.json                   # Session metadata + chunk index
  └─ session.wav                     # Optional: Stitched complete audio
```

**manifest.json Structure:**
```json
{
  "sessionId": "session-1729012345-abc123",
  "userId": "user-sub-from-cognito",
  "createdAt": "2025-10-15T03:00:00Z",
  "duration": 183.5,
  "chunkCount": 37,
  "chunkDuration": 5,
  "codec": "webm/opus",
  "sampleRate": 48000,
  "status": "completed",
  "chunks": [
    {
      "seq": 1,
      "key": "chunks/001-00000-05000.webm",
      "tStartMs": 0,
      "tEndMs": 5000,
      "bytes": 412340,
      "uploadedAt": "2025-10-15T03:00:05Z",
      "hasTranscription": true,
      "transcriptionSource": "riva-streaming"
    }
  ],
  "transcriptions": {
    "streaming": "completed",
    "batch": "pending"
  }
}
```

#### 4. Configuration

**Unified .env file:**
```bash
# From System 1 (Audio UI)
APP_NAME=dbm-cf-app-oct13
STAGE=dev
REGION=us-east-2
ACCOUNT_ID=821850226835
S3_BUCKET_NAME=dbm-test-1100-13-2025
USER_POOL_ID=us-east-2_LosMWvc1G
USER_POOL_CLIENT_ID=5rf86mbjntnhesmd9lb04g6kmp
IDENTITY_POOL_ID=us-east-2:c3a65c83-2d33-41d2-91c5-02a1b67f8b85
CLOUDFRONT_URL=https://dxl3csiag85e6.cloudfront.net
API_ENDPOINT=https://1oj6yn09u4.execute-api.us-east-2.amazonaws.com/dev/api

# From System 2 (Riva)
RIVA_WEBSOCKET_URL=wss://<BUILD_BOX_IP>:8443
RIVA_HOST=<GPU_INSTANCE_IP>
RIVA_PORT=50051
BUILD_BOX_IP=<BUILD_BOX_PUBLIC_IP>
GPU_INSTANCE_ID=i-XXXXXXXXX
GPU_INSTANCE_IP=<GPU_PRIVATE_IP>

# New: Combined endpoints
HYBRID_MODE=true
ENABLE_STREAMING_ASR=true
ENABLE_CHUNK_STORAGE=true
```

### User Flow

1. **User logs in** via Cognito (System 1 auth flow)
2. **Clicks "Record"**:
   - Browser requests mic access
   - Creates session ID
   - Initializes MediaRecorder with 5s chunks

3. **During recording** (simultaneous paths):
   - **Path 1 (Real-time):**
     - Audio → PCM16 conversion
     - Stream to WebSocket
     - Riva returns transcription
     - Display in UI immediately

   - **Path 2 (Storage):**
     - MediaRecorder produces WebM chunks
     - Request presigned URL from Lambda
     - Upload chunk to S3
     - Update manifest.json
     - Link transcription to chunk

4. **User sees**:
   - Real-time transcription from Riva (instant feedback)
   - Upload status for each chunk (green check when stored)
   - Session metadata (duration, chunk count)

5. **After recording**:
   - All chunks stored in S3
   - Manifest complete
   - Ready for batch processing (future: Whisper, speaker ID, etc.)

### Benefits of Integration

1. **Immediate Feedback:** User sees transcription in real-time via Riva
2. **Reliability:** Audio chunks stored in S3 for batch reprocessing
3. **Quality:** Can run higher-quality offline models on stored audio
4. **Redundancy:** Two transcription sources (streaming + batch)
5. **Auditability:** Complete audio archive with metadata
6. **Scalability:** CloudFront + Lambda scales automatically
7. **Cost Efficiency:** Shutdown GPU when not streaming (keep storage)

---

## Migration Path

### Phase 1: Infrastructure Merge
- [ ] Copy `api/` directory from System 1 → new repo
- [ ] Copy `src/asr/` directory from System 2 → new repo
- [ ] Copy `static/` directory from System 2 → new repo
- [ ] Copy `web/` directory from System 1 → new repo
- [ ] Merge `serverless.yml` files
- [ ] Create unified `.env.example`

### Phase 2: Frontend Integration
- [ ] Create `web/hybrid-recorder.html`
- [ ] Merge Cognito auth from System 1
- [ ] Integrate WebSocket client from System 2
- [ ] Add dual audio capture logic
- [ ] Update UI to show both paths

### Phase 3: Backend Integration
- [ ] Add `api/transcription.js` Lambda function
- [ ] Update `serverless.yml` with new endpoints
- [ ] Deploy Lambda functions
- [ ] Test presigned URL uploads

### Phase 4: WebSocket Bridge
- [ ] Deploy WebSocket bridge to build box
- [ ] Configure SSL certificates
- [ ] Test WebSocket connectivity
- [ ] Integrate with Lambda for auth

### Phase 5: GPU Deployment
- [ ] Deploy Riva to GPU instance
- [ ] Configure Conformer-CTC model
- [ ] Test gRPC connectivity
- [ ] Verify streaming performance

### Phase 6: Testing
- [ ] End-to-end recording test
- [ ] Verify dual-path operation
- [ ] Test transcription linking
- [ ] Load testing
- [ ] Security audit

### Phase 7: Documentation
- [ ] Update README with hybrid architecture
- [ ] Create deployment guide
- [ ] Document API endpoints
- [ ] Add troubleshooting guide

---

## Endpoint Summary (Integrated System)

| Endpoint | Method | Purpose | Source |
|----------|--------|---------|--------|
| `/api/data` | GET | Auth test | System 1 |
| `/api/s3/list` | GET | List files | System 1 |
| `/api/s3/upload` | POST | Upload URL | System 1 |
| `/api/audio/upload-chunk` | POST | Chunk upload URL | System 1 |
| `/api/audio/session-metadata` | POST | Update metadata | System 1 |
| `/api/audio/sessions` | GET | List sessions | System 1 |
| `/api/transcription/link` | POST | Link ASR to chunk | **NEW** |
| `wss://:8443` | WebSocket | Real-time ASR | System 2 |

---

## File Structure (Proposed)

```
nvidia-riva-conformer-streaming-ver-9-and-audio-ui-cf-s3-lambda-cognito-interface/
├── README.md                           # Unified documentation
├── INTEGRATION_ANALYSIS.md             # This file
├── .env.example                        # Combined configuration
├── .gitignore
│
├── api/                                # From System 1 (Lambda functions)
│   ├── audio.js                        # Audio chunk upload endpoints
│   ├── s3.js                           # File operations
│   ├── handler.js                      # Auth test
│   ├── memory.js                       # Memory storage
│   └── transcription.js                # NEW: Link ASR to chunks
│
├── src/asr/                            # From System 2 (Python)
│   ├── riva_client.py                  # Riva gRPC client
│   └── riva_websocket_bridge.py        # WebSocket bridge
│
├── web/                                # From System 1 (Frontend)
│   ├── index.html                      # Dashboard
│   ├── hybrid-recorder.html            # NEW: Integrated recorder
│   ├── app.js                          # Main logic + Cognito
│   └── styles.css                      # Styles
│
├── static/                             # From System 2 (WebSocket client)
│   ├── websocket-client.js             # WebSocket client
│   ├── audio-recorder.js               # Audio capture
│   └── transcription-ui.js             # UI updates
│
├── scripts/                            # Deployment scripts
│   ├── deploy-lambda.sh                # Deploy Serverless
│   ├── deploy-websocket-bridge.sh      # Deploy WebSocket bridge
│   ├── deploy-riva-gpu.sh              # Deploy Riva to GPU
│   └── deploy-all.sh                   # Full deployment
│
├── serverless.yml                      # AWS infrastructure (merged)
└── package.json                        # Node.js dependencies
```

---

## Key Decisions

### 1. Audio Format Strategy

**Challenge:** System 1 uses WebM/Opus (48kHz), System 2 uses PCM16 (16kHz)

**Solution:**
- **Primary Format:** WebM/Opus for storage (better compression)
- **Streaming Format:** PCM16 for Riva (required by model)
- **Conversion:** Browser converts WebM → PCM16 for streaming path

**Implementation:**
```javascript
// Capture at 48kHz for quality
const stream = await navigator.mediaDevices.getUserMedia({
  audio: { sampleRate: 48000 }
});

// Store as WebM/Opus (Path 2)
const mediaRecorder = new MediaRecorder(stream, {
  mimeType: 'audio/webm;codecs=opus'
});

// Convert to 16kHz PCM16 for Riva (Path 1)
const audioContext = new AudioContext({ sampleRate: 48000 });
const resampler = audioContext.createScriptProcessor(4096, 1, 1);
resampler.onaudioprocess = (e) => {
  const pcm16 = resampleTo16kPCM16(e.inputBuffer);
  websocket.send(pcm16);
};
```

### 2. Chunk Duration

**Challenge:** System 1 uses 5s-5min configurable chunks, System 2 uses 100ms chunks

**Solution:**
- **Storage chunks:** 5 seconds (good balance for S3 uploads)
- **Streaming chunks:** 100ms (required for real-time ASR)
- **Buffering:** Browser manages both timings independently

### 3. Authentication

**Challenge:** System 1 uses Cognito, System 2 uses no auth (internal network)

**Solution:**
- **Frontend → Lambda:** Cognito JWT (existing)
- **Frontend → WebSocket:** Cognito JWT passed in WebSocket headers
- **WebSocket → Riva:** No auth (internal network)

**WebSocket Auth Implementation:**
```python
# src/asr/riva_websocket_bridge.py
async def authenticate_websocket(websocket):
    # Get JWT from headers
    token = websocket.request_headers.get('Authorization')
    if not token:
        await websocket.close(1008, "Missing authorization")
        return None

    # Verify with Cognito JWKS
    user = await verify_cognito_token(token)
    if not user:
        await websocket.close(1008, "Invalid token")
        return None

    return user
```

### 4. Cost Optimization

**Challenge:** GPU costs $0.526/hour, Lambda+S3 is pay-per-use

**Solution:**
- **Development:** Use GPU only when actively recording
- **Production:** Keep GPU running 8am-8pm (business hours)
- **Storage:** Always available (cheap)
- **Scripts:** `shutdown-gpu.sh` and `startup-gpu.sh` from System 2

**Cost Estimate:**
```
GPU (12 hours/day):     $0.526/hr × 12hr × 30 days = $189/month
Lambda (10k requests):  $0.20/month (free tier)
S3 (100GB audio):       $2.30/month
API Gateway:            $3.50/month (1M requests)
CloudFront:             Free tier (1TB)
Total:                  ~$195/month (mostly GPU)
```

### 5. Deployment Strategy

**Recommended Order:**
1. Deploy Serverless backend (Lambda + S3 + Cognito)
2. Deploy static frontend to CloudFront
3. Test storage path independently
4. Deploy GPU instance with Riva
5. Deploy WebSocket bridge
6. Test streaming path independently
7. Enable dual-path mode
8. Full integration test

---

## Next Steps

To implement this integration as specified in your CLAUDE CODE RUNBOOK, we need to:

### Immediate Actions

1. **Create the new repo structure** at:
   ```
   ~/event-b/nvidia-riva-conformer-streaming-ver-9-and-audio-ui-cf-s3-lambda-cognito-interface/
   ```

2. **Build the Backend S3 Writer API** as specified in your runbook:
   - Implement `/api/audio/sessions` - Create session
   - Implement `/api/audio/sessions/{sessionId}/chunks/presign` - Presign chunk
   - Implement `/api/audio/sessions/{sessionId}/chunks/complete` - Confirm upload
   - Implement `/api/audio/sessions/{sessionId}/finalize` - Seal session

3. **Key differences from existing System 1**:
   - Your runbook specifies more granular chunk management
   - Manifest.json managed server-side (not client-side)
   - Support for multipart uploads (chunks >5MB)
   - EventBridge integration for chunk events
   - JWKS validation (more secure than current impl)

4. **Preserve from System 2**:
   - WebSocket bridge (unchanged)
   - Riva GPU setup (unchanged)
   - Real-time streaming flow (unchanged)

### Questions for You

1. **Do you want me to implement the Backend S3 Writer API now** according to your CLAUDE CODE RUNBOOK?

2. **Should I use the existing Cognito resources** from System 1, or create new ones?

3. **Do you want to keep the existing audio UI** (from System 1) or build a new one that follows your runbook's requirements?

4. **WebSocket integration:** Should the WebSocket bridge validate Cognito tokens, or should it remain unauthenticated (internal network only)?

Let me know and I can proceed with implementation!
