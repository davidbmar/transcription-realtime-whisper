# Audio API - Backend S3 Writer API

Backend API for two-pass transcription system that handles chunked audio uploads to S3 while simultaneously streaming to Riva for real-time ASR.

## Architecture

This API provides the **storage path** of the dual-path system:

```
Browser → API Gateway → Lambda → S3
  ↓
  (simultaneously)
  ↓
Browser → WebSocket → Riva → Real-time ASR
```

## Features

- ✅ **Session Management** - Create recording sessions with unique IDs
- ✅ **Presigned URL Upload** - Client uploads directly to S3 via presigned URLs
- ✅ **Chunk Tracking** - Server-side manifest.json with chunk metadata
- ✅ **User Isolation** - All S3 keys scoped to `users/{userId}/`
- ✅ **Cognito JWKS Auth** - JWT verification via Cognito public keys
- ✅ **EventBridge Integration** - Emit events for chunk uploads and session finalization
- ✅ **TypeScript** - Fully typed with Zod runtime validation

## API Endpoints

### POST /api/audio/sessions
Create a new recording session.

**Request:**
```json
{
  "codec": "webm/opus",
  "sampleRate": 48000,
  "chunkSeconds": 5,
  "deviceInfo": {
    "userAgent": "Mozilla/5.0..."
  }
}
```

**Response:**
```json
{
  "sessionId": "session-1729012345-abc123",
  "s3": {
    "bucket": "dbm-test-1100-13-2025",
    "basePrefix": "users/{userId}/audio/sessions/{sessionId}/chunks/"
  },
  "uploadStrategy": "single",
  "maxChunkBytes": 5242880
}
```

### POST /api/audio/sessions/{sessionId}/chunks/presign
Get presigned URL for chunk upload.

**Request:**
```json
{
  "seq": 1,
  "tStartMs": 0,
  "tEndMs": 5000,
  "ext": "webm",
  "sizeBytes": 412340,
  "contentType": "audio/webm"
}
```

**Response:**
```json
{
  "objectKey": "users/{userId}/audio/sessions/{sessionId}/chunks/00001-000000-005000.webm",
  "putUrl": "https://s3.amazonaws.com/...",
  "headers": {
    "Content-Type": "audio/webm",
    "x-amz-meta-user-id": "{userId}",
    "x-amz-meta-session-id": "{sessionId}",
    "x-amz-meta-seq": "1"
  },
  "expiresInSeconds": 300
}
```

### POST /api/audio/sessions/{sessionId}/chunks/complete
Confirm chunk upload and update manifest.

**Request:**
```json
{
  "seq": 1,
  "objectKey": "users/{userId}/audio/sessions/{sessionId}/chunks/00001-000000-005000.webm",
  "bytes": 412340,
  "tStartMs": 0,
  "tEndMs": 5000,
  "md5": "...",
  "sha256": "..."
}
```

**Response:**
```json
{
  "ok": true,
  "eventId": "evt-..."
}
```

### PUT /api/audio/sessions/{sessionId}/manifest
Optional client-side manifest upsert (prefer server-side via complete).

**Request:**
```json
{
  "sessionId": "{sessionId}",
  "codec": "webm/opus",
  "sampleRate": 48000,
  "chunks": [
    {
      "seq": 1,
      "key": "users/{userId}/audio/sessions/{sessionId}/chunks/00001-000000-005000.webm",
      "tStartMs": 0,
      "tEndMs": 5000,
      "bytes": 412340
    }
  ],
  "final": false
}
```

**Response:**
```json
{
  "ok": true,
  "manifestKey": "users/{userId}/audio/sessions/{sessionId}/manifest.json"
}
```

### POST /api/audio/sessions/{sessionId}/finalize
Seal manifest and emit RecordingFinalized event.

**Request:**
```json
{
  "durationMs": 183000,
  "final": true
}
```

**Response:**
```json
{
  "ok": true,
  "manifestKey": "users/{userId}/audio/sessions/{sessionId}/manifest.json",
  "chunkCount": 37,
  "totalBytes": 15234567
}
```

## S3 Object Model

```
s3://dbm-test-1100-13-2025/
└─ users/
   └─ {userId}/
      └─ audio/
         └─ sessions/
            └─ {sessionId}/
               ├─ chunks/
               │  ├─ 00001-000000-005000.webm
               │  ├─ 00002-005000-010000.webm
               │  └─ ...
               └─ manifest.json
```

**manifest.json Structure:**
```json
{
  "sessionId": "session-1729012345-abc123",
  "userId": "user-sub-from-cognito",
  "codec": "webm/opus",
  "sampleRate": 48000,
  "chunks": [
    {
      "seq": 1,
      "key": "users/{userId}/audio/sessions/{sessionId}/chunks/00001-000000-005000.webm",
      "tStartMs": 0,
      "tEndMs": 5000,
      "bytes": 412340,
      "uploadedAt": "2025-10-15T03:00:05Z",
      "md5": "...",
      "sha256": "..."
    }
  ],
  "final": false,
  "createdAt": "2025-10-15T03:00:00Z",
  "updatedAt": "2025-10-15T03:00:05Z",
  "totalBytes": 412340,
  "durationMs": 5000
}
```

## Setup

### 1. Install Dependencies
```bash
cd audio-api
npm install
```

### 2. Configure Environment
```bash
cp .env.example .env
# Edit .env with your AWS account details
```

### 3. Build TypeScript
```bash
npm run build
```

### 4. Deploy to AWS
```bash
npm run deploy
# or
serverless deploy --stage dev
```

### 5. Get Deployed URL
```bash
serverless info --stage dev
```

## Development

### Run Locally (Serverless Offline)
```bash
npm run local
```

### Lint Code
```bash
npm run lint
```

### Run Tests
```bash
npm test
```

## Authentication

All endpoints require a valid Cognito JWT token in the `Authorization` header:

```
Authorization: Bearer {id_token}
```

The token is verified using JWKS from the Cognito User Pool. The `sub` claim is extracted as the `userId` and used for S3 key prefix enforcement.

## Security

- **User Isolation:** All S3 keys enforced to start with `users/{userId}/`
- **Prefix Validation:** Server validates that client-provided keys match user prefix
- **JWKS Validation:** Cognito public keys cached and verified on each request
- **Presigned URLs:** Expire in 5 minutes
- **S3 Encryption:** SSE-AES256 enabled on all uploads

## EventBridge Events

### AudioChunkUploaded
Emitted when a chunk upload is confirmed.

```json
{
  "Source": "audio.api",
  "DetailType": "AudioChunkUploaded",
  "Detail": {
    "userId": "...",
    "sessionId": "...",
    "chunkSeq": 1,
    "chunkKey": "users/{userId}/audio/sessions/{sessionId}/chunks/00001-000000-005000.webm",
    "bytes": 412340,
    "timestamp": "2025-10-15T03:00:05Z"
  }
}
```

### RecordingFinalized
Emitted when a session is finalized.

```json
{
  "Source": "audio.api",
  "DetailType": "RecordingFinalized",
  "Detail": {
    "userId": "...",
    "sessionId": "...",
    "manifestKey": "users/{userId}/audio/sessions/{sessionId}/manifest.json",
    "chunkCount": 37,
    "totalBytes": 15234567,
    "durationMs": 183000,
    "timestamp": "2025-10-15T03:03:05Z"
  }
}
```

## TODOs

- [ ] Implement multipart upload for chunks > 5MB
- [ ] Add batch retry endpoint for failed chunks
- [ ] Add list sessions endpoint
- [ ] Add get session metadata endpoint
- [ ] Add delete session endpoint
- [ ] Implement KMS encryption (vs SSE-AES256)
- [ ] Add CloudWatch metrics and alarms
- [ ] Add X-Ray tracing
- [ ] Add integration tests

## License

MIT
