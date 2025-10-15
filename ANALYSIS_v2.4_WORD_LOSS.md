# Analysis: Word Loss Still Occurring in v2.4.0 (Orphan Detection)

## Executive Summary
Despite implementing the "reconcile and commit" orphan detection algorithm recommended by ChatGPT and Gemini 2.5 Pro, we're still losing words during continuous speech (counting test). The root cause appears to be **premature clearing of pending tokens** due to the 12-second segment break timeout, which happens BEFORE finals arrive and orphan detection can rescue the words.

## Test Results

### User Action
Counted from 1 to 28 continuously.

### Expected Result
All numbers 1-28 captured, approximately 37+ words total (intro phrase + 28 numbers).

### Actual Result
```
Final transcript: "Getting this to work 're going to start counting now one two three four five six seven eight eleven Eleven twelve thirteen fourteenteen sixteen seeen eighteen nineteen tw twenty one twenty two twenty twenty twenty twenty twenty twenty three twenty four twenty five twentix twenty seven twenty eight"

Words: 38 stable words
Missing numbers: 9, 10, 15, 17
Errors: "fourteenteen", "seeen", "tw", "twentix", duplicate "Eleven"
```

## Log Analysis

### Critical Events Timeline

**FINAL #1 (06:19:08)**: ✅ CORRECT
```
Input: 'Getting this to work'
Context: 0 stable + 3 pending = 3 tokens
Result: Committed 4 NEW tokens
```

**FINAL #2 (06:19:10)**: ✅ ORPHAN DETECTION WORKED
```
Input: ''re going to start counting now'
Context: 4 stable + 6 pending = 10 tokens
Found overlap: 6 tokens match
Final covers: 0 context tokens
Orphaned: 6 pending tokens
Result: ✓ Committed 6 ORPHANED tokens (from partials, not in final)
Stable text now: "Getting this to work 're going to start counting now" (10 words)
```

**FINAL #3 (06:19:22)**: ❌ PROBLEM - Missing numbers 9, 10
```
Input: 'One two three four five six seven eight'  ← Only 8 numbers, missing 9, 10!
Context: 11 stable + 0 pending = 11 tokens  ← PENDING IS EMPTY!
Found overlap: 1 token
Final covers: 7 context tokens
Orphaned: 0 pending tokens  ← CAN'T RESCUE WORDS, PENDING ALREADY EMPTY!
Result: ✓ Committed 7 NEW tokens
```

**Between FINAL #2 and FINAL #3 (12 seconds gap)**: 🚨 ROOT CAUSE
```
Browser logs show:
- 06:19:10 → 06:19:22 (12 second gap)
- Multiple display events: "11 stable words, 1 pending → 0 pending" (repeat)
- Segment break at 1:19:14: "segment=0" → "segment=1"
- This suggests pending tokens were CLEARED by forced segment break
```

**FINAL #4 (06:19:34)**: ❌ PROBLEM - Missing numbers
```
Input: 'Eleven twelve thirteen fourteenteen sixteen seeen eighteen nineteen tw twenty one twenty two'
Context: 19 stable + 4 pending = 23 tokens
Final covers: 13 context tokens
Orphaned: 0 pending tokens  ← AGAIN, CAN'T RESCUE BECAUSE PENDING WAS ALREADY CLEARED
Result: Committed 13 NEW tokens (but notice errors: "fourteenteen", "seeen", "tw")
```

## Root Cause Analysis

### The Problem: Timing Race Condition

1. **User speaks continuously**: "one two three four five six seven eight nine ten eleven..."

2. **RIVA sends partials** with sliding window:
   - Partial: "one"
   - Partial: "one two"
   - Partial: "two three"
   - ...partials with "nine", "ten", "eleven"...

3. **Accumulator processes partials**:
   - Tokens enter pending buffer with K-confirmation tracking
   - But speech is continuous, so tokens don't reach K=3 confirmations quickly enough

4. **12-SECOND SEGMENT TIMEOUT FIRES** (at 06:19:14):
   - `_force_segment_break()` commits ALL pending tokens
   - Pending buffer CLEARED
   - Segment ID increments: segment=0 → segment=1

5. **RIVA FINAL ARRIVES** (8 seconds later, at 06:19:22):
   - Final contains: "One two three four five six seven eight" (missing 9, 10)
   - Orphan detection looks for: `num_orphaned = len(pending) - covered_len`
   - But `len(pending) = 0` because segment break already cleared it!
   - **Lost words "nine" and "ten" are GONE** - not in final, not in pending

### Why Orphan Detection Fails

The orphan detection algorithm assumes:
```
pending_tokens = words that appeared in recent partials but not yet committed
```

But in reality:
```
pending_tokens = words in partials AND haven't been cleared by segment break
```

When segment break fires before a final arrives, pending tokens are committed with the OLD segment context, and the buffer is cleared. When the final arrives later, it can't rescue words that were dropped by RIVA's sliding window because those words are no longer in the pending buffer.

## Configuration Analysis

Current settings from `.env`:
```bash
ACCUMULATOR_STABILITY_THRESHOLD=3          # K=3 confirmations
ACCUMULATOR_FORCED_FLUSH_MS=2000           # T=2 seconds
ACCUMULATOR_MAX_SEGMENT_S=12.0             # 12 second segment timeout
```

### The Conflict

- **Fast continuous speech**: Numbers spoken every ~0.5-1 seconds
- **RIVA partial cadence**: ~300ms intervals (RIVA_PARTIAL_RESULT_INTERVAL_MS=300)
- **Segment timeout**: 12 seconds
- **Problem**: During 12 seconds of continuous counting (1-24 numbers), segment break fires and clears pending buffer before finals can confirm/correct

## Questions for ChatGPT/Gemini

1. **Should we eliminate the segment break timeout entirely?**
   - Pro: Allows orphan detection to work across longer continuous speech
   - Con: Segment could grow indefinitely, no natural break points

2. **Should segment break NOT clear pending tokens?**
   - Current: `_force_segment_break()` commits all pending and clears buffer
   - Alternative: Keep pending buffer across segment boundaries?
   - Question: Does this violate the semantic meaning of "segment"?

3. **Should we track a "partial history" separately from pending buffer?**
   - Store last N partials (or last 30 seconds of partial text) in a separate buffer
   - When final arrives, check partial history for words that were dropped
   - This way, orphan detection works even if pending was cleared by segment break

4. **Are we fundamentally misunderstanding RIVA's timing model?**
   - Do finals always arrive within the same segment as their partials?
   - Or can a final arrive after segment break, confirming words from a previous segment?
   - Should we be building a different data structure entirely?

5. **Alternative architecture: Should we abandon segments entirely?**
   - Use a simpler model: single growing transcript with forced breaks only on user action (stop transcription)
   - Keep pending buffer alive for entire session
   - Only commit tokens by: (a) K-confirmation, (b) T-forced-flush, or (c) finals

## Evidence from Logs

**Segment Break Behavior** (need to find in logs):
```bash
# Look for: "Max segment duration reached, forcing break"
# This should show at 06:19:14 (segment=0 → segment=1)
```

**Pending Token Lifecycle**:
```
06:19:10: FINAL #2 clears 6 pending
06:19:10-06:19:22: Pending goes 1→0, 1→0, 1→0 repeatedly
06:19:14: Segment break (likely cleared pending here)
06:19:22: FINAL #3 arrives, pending already empty
```

## Proposed Solutions (for AI consultation)

### Option A: Disable Segment Breaks During Active Speech
- Only break on silence detection or explicit stop
- Pros: Orphan detection works as designed
- Cons: Need VAD/silence detection

### Option B: Keep Partial History Buffer
```python
class TranscriptAccumulator:
    def __init__(self):
        self.partial_history = []  # List[(timestamp, text)]
        self.partial_history_window_s = 30.0

    def add_final(self, text: str):
        # Build context from: stable_tail + pending + recent_partial_history
        recent_partials = self._get_recent_partial_text()
        context = stable_tail + pending_texts + recent_partials
        # Then run orphan detection
```

### Option C: Delay Segment Break Until After Final
- Track time since last final
- Only trigger segment break if: (duration > 12s) AND (no recent partials)
- This ensures finals have a chance to reconcile before break

### Option D: Smarter Segment Break (Don't Clear Pending)
```python
def _force_segment_break(self, current_time: float):
    # Increment segment ID but DON'T clear pending
    self.segment_id += 1
    self.segment_start_time = current_time
    # Pending tokens carry over to next segment
```

## System Configuration

- **RIVA Version**: 2.19.0
- **Model**: conformer-ctc-xl-en-us-streaming-asr-bls-ensemble
- **Streaming Config**: chunk_size=0.16s, padding=1.92s, ms_per_timestep=40
- **Partial Interval**: 300ms
- **Python**: Async gRPC streaming with WebSocket bridge

## Next Steps

Please review this analysis and advise on:
1. Which solution approach is most sound for streaming ASR?
2. Are we misunderstanding how segments should work?
3. Should orphan detection span across segment boundaries?
4. Is there a better architectural pattern we're missing?
