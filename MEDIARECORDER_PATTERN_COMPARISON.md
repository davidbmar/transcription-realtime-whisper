# MediaRecorder Pattern Comparison: Audio-UI vs Hybrid Demo

## The Problem

**Only the first audio chunk is playable. Chunks 2, 3, 4, etc. won't play.**

This happens when you use MediaRecorder with a timeslice parameter.

---

## Pattern Comparison

### ❌ **BROKEN PATTERN (hybrid-demo.html - Original)**

```javascript
// Start with timeslice
this.mediaRecorder.start(5000);  // ← PROBLEM: Timeslice parameter

// Automatic ondataavailable every 5 seconds
this.mediaRecorder.ondataavailable = async (event) => {
    if (event.data.size > 0) {
        await this.uploadChunk(event.data, seq, ...);
        this.chunkSequence++;
    }
};
```

**Why it breaks:**
- `start(5000)` tells MediaRecorder: "Fire `ondataavailable` every 5 seconds"
- This creates **dependent chunks**:
  - Chunk 1: Full WebM file (headers + codec info + data) ✅ PLAYABLE
  - Chunk 2: Continuation only (no headers, no codec info) ❌ NOT PLAYABLE
  - Chunk 3: Continuation only ❌ NOT PLAYABLE

**WebM file structure with timeslice:**
```
Chunk 1: [EBML Header][Segment Info][Tracks][Cluster 1 Data]  ← Complete file
Chunk 2:                                      [Cluster 2 Data]  ← Missing headers!
Chunk 3:                                      [Cluster 3 Data]  ← Missing headers!
```

---

### ✅ **WORKING PATTERN (audio-ui + hybrid-demo-fixed.html)**

```javascript
// Start WITHOUT timeslice
this.mediaRecorder.start();  // ← No parameter!

// Manual timer to control chunks
scheduleNextChunk() {
    this.chunkTimer = setTimeout(() => {
        if (this.isRecording) {
            this.createChunkFromCurrentRecording();
        }
    }, 5000);  // ← We control timing
}

async createChunkFromCurrentRecording() {
    const chunks = [];

    // Set up promise to collect data
    const chunkPromise = new Promise((resolve) => {
        this.mediaRecorder.ondataavailable = (event) => {
            if (event.data.size > 0) {
                chunks.push(event.data);
            }
        };

        this.mediaRecorder.onstop = () => {
            const audioBlob = new Blob(chunks, { type: 'audio/webm;codecs=opus' });
            resolve(audioBlob);
        };
    });

    // STOP the recorder (triggers ondataavailable + onstop)
    this.mediaRecorder.stop();
    const audioBlob = await chunkPromise;

    // Upload complete chunk
    await this.uploadChunk(audioBlob, ...);

    // START NEW MediaRecorder
    await this.startNewChunkRecording();

    // Schedule next chunk
    this.scheduleNextChunk();
}

async startNewChunkRecording() {
    const mediaRecorder = new MediaRecorder(this.mediaStream, options);
    this.mediaRecorder = mediaRecorder;
    mediaRecorder.start();  // Fresh start, no timeslice!
}
```

**Why it works:**
- Each `stop()` creates a **complete independent file**
- Each new `start()` initializes fresh headers
- Every chunk is a valid WebM file

**WebM file structure with stop/restart:**
```
Chunk 1: [EBML Header][Segment Info][Tracks][Cluster 1 Data]  ← Complete file ✅
Chunk 2: [EBML Header][Segment Info][Tracks][Cluster 2 Data]  ← Complete file ✅
Chunk 3: [EBML Header][Segment Info][Tracks][Cluster 3 Data]  ← Complete file ✅
```

---

## Line-by-Line Comparison

### **Audio-UI Project (audio.html:344-461)**

```javascript
// TIMER: React useEffect with setInterval
useEffect(() => {
    let interval;
    if (isRecording) {
        interval = setInterval(() => {
            setCurrentTime(prev => {
                const newTime = prev + 1;

                // Check if we need to create a new chunk
                if (newTime > 0 && newTime % chunkDuration === 0) {
                    log(`Chunk ${currentChunkRef.current + 1} completed at ${newTime}s`);
                    createChunkFromCurrentRecording();  // ← Trigger chunk creation
                }

                return newTime;
            });
        }, 1000);  // Every 1 second, check if it's time for new chunk
    }
    return () => clearInterval(interval);
}, [isRecording, chunkDuration]);

// CHUNK CREATION: Stop old recorder, collect data, start new recorder
const createChunkFromCurrentRecording = async () => {
    if (!mediaRecorderRef.current || mediaRecorderRef.current.state !== 'recording') {
        log("ERROR: Cannot create chunk - MediaRecorder not recording");
        return;
    }

    try {
        const chunks = [];
        const oldRecorder = mediaRecorderRef.current;  // ← Save reference to OLD recorder

        // Promise to collect all data from this chunk
        const chunkPromise = new Promise((resolve) => {
            oldRecorder.ondataavailable = (event) => {
                if (event.data.size > 0) {
                    chunks.push(event.data);
                }
            };

            oldRecorder.onstop = () => {
                if (chunks.length > 0) {
                    const audioBlob = new Blob(chunks, { type: 'audio/webm;codecs=opus' });
                    resolve(audioBlob);
                } else {
                    resolve(null);
                }
            };
        });

        oldRecorder.stop();  // ← STOP triggers ondataavailable + onstop
        const audioBlob = await chunkPromise;

        if (audioBlob) {
            const chunkNumber = currentChunkRef.current + 1;
            currentChunkRef.current = chunkNumber;

            // Create local playback object
            const audioUrl = URL.createObjectURL(audioBlob);
            const newRecording = {
                id: `${sessionIdRef.current}-chunk-${chunkNumber}`,
                audioBlob,
                audioUrl  // ← Can play immediately in browser!
            };

            setRecordings(prev => [newRecording, ...prev]);

            // Upload to S3 in background
            uploadChunk(audioBlob, chunkNumber).then(success => {
                // Update sync status
            });
        }

        // START NEW RECORDER if still recording
        if (streamRef.current && isRecording) {
            await startNewChunkRecording();  // ← Fresh MediaRecorder
        }

    } catch (error) {
        log(`ERROR creating chunk: ${error.message}`);
    }
};

// START NEW CHUNK: Create fresh MediaRecorder instance
const startNewChunkRecording = async () => {
    try {
        // Detect supported MIME type
        const mimeTypes = [
            'audio/webm;codecs=opus',
            'audio/webm',
            'audio/mp4',
            'audio/ogg;codecs=opus',
            'audio/wav'
        ];

        let selectedMimeType = '';
        for (const mimeType of mimeTypes) {
            if (MediaRecorder.isTypeSupported(mimeType)) {
                selectedMimeType = mimeType;
                break;
            }
        }

        const options = selectedMimeType ? { mimeType: selectedMimeType } : {};
        const mediaRecorder = new MediaRecorder(streamRef.current, options);

        mediaRecorderRef.current = mediaRecorder;  // ← Replace old recorder

        mediaRecorder.onerror = (event) => {
            log(`MediaRecorder error: ${event.error}`);
        };

        mediaRecorder.start();  // ← NO TIMESLICE!
        log("New chunk recording started");

    } catch (error) {
        log(`ERROR starting new chunk: ${error.message}`);
    }
};
```

### **Hybrid Demo Fixed (hybrid-demo-fixed.html)**

```javascript
// TIMER: setTimeout-based scheduling
scheduleNextChunk() {
    this.chunkTimer = setTimeout(() => {
        if (this.isRecording) {
            this.createChunkFromCurrentRecording();  // ← Trigger chunk creation
        }
    }, CONFIG.chunkDuration * 1000);  // 5 seconds
}

// CHUNK CREATION: Exact same pattern as audio-ui
async createChunkFromCurrentRecording() {
    if (!this.mediaRecorder || this.mediaRecorder.state !== 'recording') {
        this.log("ERROR: Cannot create chunk - MediaRecorder not recording", 'error');
        return;
    }

    try {
        const chunks = [];
        const chunkStartTime = this.chunkSequence * CONFIG.chunkDuration * 1000;
        const chunkEndTime = (this.chunkSequence + 1) * CONFIG.chunkDuration * 1000;

        const chunkPromise = new Promise((resolve) => {
            this.mediaRecorder.ondataavailable = (event) => {
                if (event.data.size > 0) {
                    chunks.push(event.data);
                }
            };

            this.mediaRecorder.onstop = () => {
                if (chunks.length > 0) {
                    const audioBlob = new Blob(chunks, { type: 'audio/webm;codecs=opus' });
                    resolve(audioBlob);
                } else {
                    resolve(null);
                }
            };
        });

        // Stop the recorder to get the data
        this.mediaRecorder.stop();
        const audioBlob = await chunkPromise;

        if (audioBlob) {
            this.log(`Chunk ${this.chunkSequence + 1} captured (${audioBlob.size} bytes)`);

            // Upload chunk in background
            this.uploadChunk(audioBlob, this.chunkSequence, chunkStartTime, chunkEndTime);
            this.chunkSequence++;
        }

        // Start new recorder if still recording
        if (this.mediaStream && this.isRecording) {
            await this.startNewChunkRecording();
            this.scheduleNextChunk();  // ← Schedule next chunk
        }

    } catch (error) {
        this.log(`ERROR creating chunk: ${error.message}`, 'error');
    }
}

// START NEW CHUNK: Same as audio-ui
async startNewChunkRecording() {
    try {
        const mimeTypes = [
            'audio/webm;codecs=opus',
            'audio/webm',
            'audio/mp4',
            'audio/ogg;codecs=opus'
        ];

        let selectedMimeType = '';
        for (const mimeType of mimeTypes) {
            if (MediaRecorder.isTypeSupported(mimeType)) {
                selectedMimeType = mimeType;
                break;
            }
        }

        const options = selectedMimeType ? { mimeType: selectedMimeType } : {};
        this.mediaRecorder = new MediaRecorder(this.mediaStream, options);

        this.mediaRecorder.onerror = (event) => {
            this.log(`MediaRecorder error: ${event.error}`, 'error');
        };

        // Start without timeslice - we'll stop manually
        this.mediaRecorder.start();
        this.log(`New chunk recording started (${selectedMimeType})`);

    } catch (error) {
        this.log(`ERROR starting chunk: ${error.message}`, 'error');
    }
}
```

---

## Key Differences: Audio-UI vs Hybrid-Fixed

| Aspect | Audio-UI | Hybrid-Fixed |
|--------|----------|--------------|
| **Timer Mechanism** | React `setInterval` (1s ticks) | JavaScript `setTimeout` (chunk duration) |
| **Chunk Trigger** | Check `newTime % chunkDuration === 0` | Direct timeout callback |
| **State Management** | React hooks (`useRef`, `useState`) | Class instance properties |
| **Local Playback** | Creates `audioUrl` for browser playback | Uploads only (no local playback UI) |
| **Stop/Restart Pattern** | ✅ Identical | ✅ Identical |
| **Promise Pattern** | ✅ Identical | ✅ Identical |
| **MIME Detection** | ✅ Identical | ✅ Identical |
| **Result** | ✅ All chunks playable | ✅ All chunks playable |

---

## Why Both Work

Both implementations follow the **same core pattern**:

1. **Start MediaRecorder without timeslice**
   ```javascript
   mediaRecorder.start();  // NO parameter
   ```

2. **Use external timer** to decide when to create chunks
   - Audio-UI: `setInterval(() => { if (time % duration === 0) create() }, 1000)`
   - Hybrid: `setTimeout(() => create(), duration * 1000)`

3. **Stop old recorder**
   ```javascript
   oldRecorder.stop();  // Triggers ondataavailable + onstop
   ```

4. **Collect data via promise**
   ```javascript
   const chunkPromise = new Promise((resolve) => {
       oldRecorder.ondataavailable = (e) => chunks.push(e.data);
       oldRecorder.onstop = () => resolve(new Blob(chunks));
   });
   ```

5. **Create NEW MediaRecorder**
   ```javascript
   const newRecorder = new MediaRecorder(stream, options);
   newRecorder.start();  // Fresh start, new headers!
   ```

6. **Schedule next chunk**
   - Audio-UI: Automatic via `setInterval` loop
   - Hybrid: Explicit via `scheduleNextChunk()`

---

## What Makes Chunks Playable

Each chunk needs these WebM elements to be independently playable:

```
[EBML Header]          ← File format signature
[Segment Info]         ← Metadata about the segment
[Tracks]               ← Audio codec, sample rate, etc.
[Cluster Data]         ← Actual audio samples
```

**With timeslice (`start(5000)`):**
- Only first chunk gets full headers
- Subsequent chunks are just cluster data

**With stop/restart:**
- Every `stop()` + `start()` sequence creates a new file
- Each chunk gets its own complete headers

---

## Testing: How to Verify

### Download and Play Test

```bash
# Download chunks from S3
aws s3 cp s3://dbm-test-1100-13-2025/users/xxx/chunks/00001-000000-005000.webm ./chunk1.webm
aws s3 cp s3://dbm-test-1100-13-2025/users/xxx/chunks/00002-005000-010000.webm ./chunk2.webm
aws s3 cp s3://dbm-test-1100-13-2025/users/xxx/chunks/00003-010000-015000.webm ./chunk3.webm

# Try to play each chunk
ffplay chunk1.webm  # ← Should work
ffplay chunk2.webm  # ← Should work (if using stop/restart)
ffplay chunk3.webm  # ← Should work (if using stop/restart)
```

### Browser Audio Element Test

```javascript
// In browser console after recording
const recordings = document.querySelectorAll('audio');
recordings.forEach((audio, i) => {
    console.log(`Chunk ${i + 1}:`, audio.src);
    audio.play().then(() => {
        console.log(`✓ Chunk ${i + 1} plays successfully`);
    }).catch(err => {
        console.log(`✗ Chunk ${i + 1} failed: ${err.message}`);
    });
});
```

### File Header Test

```bash
# Check WebM headers with ffprobe
ffprobe -v error -show_format -show_streams chunk1.webm
ffprobe -v error -show_format -show_streams chunk2.webm

# Both should show:
# - format_name=matroska,webm
# - codec_name=opus (or vorbis)
# - Complete stream info
```

---

## Summary

| Pattern | Chunks Playable? | Why? |
|---------|------------------|------|
| `start(5000)` with `ondataavailable` | ❌ Only first | Continuation chunks lack headers |
| `start()` then `stop()` + restart | ✅ All chunks | Each stop/start creates complete file |

**The fix:** Use the stop/restart pattern from audio-ui, which both implementations now follow correctly.

---

## Access Fixed Demo

```
https://3.16.124.227:8444/hybrid-demo-fixed.html
```

All chunks will now be independently playable! 🎉
