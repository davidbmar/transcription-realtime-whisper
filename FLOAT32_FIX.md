# Float32 PCM Fix - Why Transcriptions Weren't Working

## Problem
WhisperLive was receiving audio and processing it (GPU logs showed "Processing audio with duration..."), but **NO transcriptions were being sent back to the browser**.

## Root Cause
**WhisperLive expects Float32 PCM audio, NOT Int16 PCM!**

Our initial browser clients were:
- `test-whisper.html`: Converting Float32 → Int16 before sending
- `index.html`: Sending WebM/Opus compressed audio

Neither format worked with WhisperLive.

## Solution Discovery
ChatGPT provided the critical insight:

> **Step 5 — Verify audio payload (this is a common gotcha)**
>
> Most WhisperLive browser examples send Float32 PCM, not Int16. Your current code converts to Int16; change to Float32:
>
> - **What to send**: 16,000 Hz, mono, **Float32Array**, values in [-1.0, +1.0]
> - **Framing**: Send **raw binary frames** (`ws.send(float32.buffer)`) after the one-time JSON config.

## Testing Confirmation
Created `test_client.py` that:
1. Connected to WhisperLive at GPU:9090
2. Converted WebM test file to Float32 PCM using ffmpeg
3. Sent Float32 chunks to WhisperLive
4. **SUCCESS!** Received full transcriptions with segments

Example transcription response:
```json
{
  "uid": "test-client-001",
  "segments": [
    {
      "start": "0.000",
      "end": "2.816",
      "text": " My brain kind of explodes a little bit.",
      "completed": false
    }
  ]
}
```

## Implementation Fix

### Before (WRONG - Int16):
```javascript
function float32ToInt16(buffer) {
    const l = buffer.length;
    const buf = new Int16Array(l);
    for (let i = 0; i < l; i++) {
        buf[i] = Math.min(1, buffer[i]) * 0x7FFF;
    }
    return buf.buffer;
}

processor.onaudioprocess = (e) => {
    const audioData = e.inputBuffer.getChannelData(0);
    const pcmData = float32ToInt16(audioData);  // ❌ WRONG!
    ws.send(pcmData);
};
```

### After (CORRECT - Float32):
```javascript
processor.onaudioprocess = (e) => {
    // Send Float32Array directly - WhisperLive expects Float32!
    const audioData = e.inputBuffer.getChannelData(0);  // Already Float32Array
    ws.send(audioData.buffer);  // ✅ CORRECT!
};
```

## Files Updated
1. `site/test-whisper.html` - Removed Int16 conversion, send Float32 directly
2. `site/index.html` - Replaced MediaRecorder (WebM/Opus) with AudioContext (Float32 PCM)
3. `test_client.py` - Python test client using Float32 PCM

## Audio Format Requirements
- **Sample Rate**: 16,000 Hz
- **Channels**: 1 (mono)
- **Format**: Float32 PCM (32-bit float, little-endian)
- **Values**: Float values in range [-1.0, +1.0]
- **Chunk Size**: 4096 samples = 16,384 bytes (4096 samples × 4 bytes per float)

## Browser Audio Setup
```javascript
// Create AudioContext at 16kHz
audioContext = new AudioContext({ sampleRate: 16000 });
const source = audioContext.createMediaStreamSource(mediaStream);

// Create ScriptProcessor for raw audio access
processor = audioContext.createScriptProcessor(4096, 1, 1);

processor.onaudioprocess = (e) => {
    const audioData = e.inputBuffer.getChannelData(0);  // Float32Array
    ws.send(audioData.buffer);  // Send raw ArrayBuffer
};

source.connect(processor);
processor.connect(audioContext.destination);
```

## ffmpeg Conversion (for testing)
```bash
# Convert WebM/Opus to Float32 PCM
ffmpeg -i input.webm \
  -f f32le \
  -acodec pcm_f32le \
  -ar 16000 \
  -ac 1 \
  -y output.pcm
```

## Transcription Response Format
WhisperLive sends JSON messages with this structure:

```json
{
  "uid": "client-id",
  "segments": [
    {
      "start": "0.000",       // Start time in seconds
      "end": "2.816",         // End time in seconds
      "text": " ...",         // Transcribed text
      "completed": false      // true = final, false = partial
    }
  ]
}
```

- Multiple segments can be sent in one message
- `completed: false` = partial/interim result (may change)
- `completed: true` = final result (won't change)
- Segments are sent continuously as audio is processed

## Key Takeaway
**Always use Float32 PCM for WhisperLive, never Int16 or compressed formats!**

This is different from many other ASR systems that accept Int16 PCM or compressed audio.
