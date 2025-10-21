# Visual Guide: Timestamp-Based Transcript Accumulator

This document provides visual explanations of the key concepts.

---

## 1. The Finalization Fence Concept

```
═══════════════════════════════════════════════════════════════════
TIMELINE (Absolute Time - Seconds from Recording Start)
═══════════════════════════════════════════════════════════════════

0s ────────────────────────────────────────────────────── 7.0s (liveEdge)
                                                          │
                                                          │
                           ┌──────────────────────────────┤
                           │      lockWindow (2.0s)       │
                           │                              │
                           5.0s ◄── finalizationFence     │
                           │                              │
                           │                              │
┌──────────────────────────┼──────────────────────────────┼───────┐
│  IMMUTABLE (Locked)      │   MUTABLE (Unlocked)         │       │
│  ✓ Cannot be modified    │   ⚡ Can be refined          │       │
│  ✓ Stable for users      │   ⚡ Subject to change        │       │
│  ✓ Safe to display       │   ⚡ Preview only            │       │
└──────────────────────────┴──────────────────────────────┴───────┘

Segments in timeline:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[0.0-1.5] hello          ← LOCKED (immutable)
[1.5-2.8] world          ← LOCKED (immutable)
[2.8-3.5] how            ← LOCKED (immutable)
[3.5-4.2] are            ← LOCKED (immutable)
[4.2-5.0] you            ← LOCKED (immutable)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                         ↑ finalizationFence (5.0s)
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
[5.0-6.2] doing          ← UNLOCKED (mutable)
[6.2-7.0] fine           ← UNLOCKED (mutable)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

As liveEdge moves forward (e.g., to 8.0s):
- finalizationFence moves to 6.0s
- Segments [5.0-6.0] transition from unlocked → locked
- New segments [7.0-8.0] arrive as unlocked
```

---

## 2. Sliding Window Behavior with Timestamps

```
═══════════════════════════════════════════════════════════════════
WHISPERLIVE PROCESSING WINDOWS (Overlapping Audio Chunks)
═══════════════════════════════════════════════════════════════════

Audio Stream:
|─────────────────────────────────────────────────────►
0s   1s   2s   3s   4s   5s   6s   7s   8s   9s   10s


Window A (0.0 - 5.0s):
[────────────────────────]
 ↓ Model processes
 ↓ Outputs segments with timestamps
 │
 ├─ Segment: "hello world how are you"
 │  start: 0.0, end: 5.0


Window B (2.5 - 7.5s):  ← Overlaps A by 2.5s
         [────────────────────────]
          ↓ Model re-processes 2.5-5.0s
          ↓ May refine previous output
          │
          ├─ Segment: "hello world how are you"  ← Same as A
          │  start: 0.0, end: 5.0, completed: true
          │
          └─ Segment: "how are you doing fine"    ← New refinement
             start: 2.8, end: 7.2


Window C (5.0 - 10.0s):
                  [────────────────────────]
                   ↓ Model processes new audio
                   │
                   ├─ Segment: "doing fine today"
                      start: 5.5, end: 9.0


═══════════════════════════════════════════════════════════════════
KEY INSIGHT: Timestamps are ABSOLUTE (relative to recording start)
- "how" appears at ~2.8s in both Window A and Window B
- Same timestamp = same segment (even if text refined)
═══════════════════════════════════════════════════════════════════
```

---

## 3. Timestamp Matching with Jitter Tolerance

```
═══════════════════════════════════════════════════════════════════
FUZZY TIMESTAMP MATCHING (±100ms tolerance)
═══════════════════════════════════════════════════════════════════

Window A reports:
┌─────────────────────────────────────┐
│ Segment: "how are you"              │
│ start: 2.800s                       │
│ end:   4.200s                       │
└─────────────────────────────────────┘

Window B reports (same text, slightly different timestamps):
┌─────────────────────────────────────┐
│ Segment: "how are you"              │
│ start: 2.850s  ◄─ 50ms jitter       │
│ end:   4.180s  ◄─ 20ms jitter       │
└─────────────────────────────────────┘

Matching logic:
│ abs(2.800 - 2.850) = 0.050s ≤ 0.100s ✓ MATCH
│ abs(4.200 - 4.180) = 0.020s ≤ 0.100s ✓ MATCH
└─► Conclusion: Same segment, UPDATE text (if different)


Window C reports (different text, similar timestamps):
┌─────────────────────────────────────┐
│ Segment: "how old are you"          │
│ start: 2.820s  ◄─ 20ms jitter       │
│ end:   4.190s  ◄─ 10ms jitter       │
└─────────────────────────────────────┘

Matching logic:
│ abs(2.800 - 2.820) = 0.020s ≤ 0.100s ✓ MATCH
│ abs(4.200 - 4.190) = 0.010s ≤ 0.100s ✓ MATCH
└─► Conclusion: Same segment, UPDATE text "how are you" → "how old are you"


Window D reports (completely different timestamps):
┌─────────────────────────────────────┐
│ Segment: "doing fine"               │
│ start: 5.500s  ◄─ 2.7s difference!  │
│ end:   6.800s                       │
└─────────────────────────────────────┘

Matching logic:
│ abs(2.800 - 5.500) = 2.700s > 0.100s ✗ NO MATCH
└─► Conclusion: Different segment, INSERT new entry
```

---

## 4. State Transitions for Segments

```
═══════════════════════════════════════════════════════════════════
SEGMENT LIFECYCLE
═══════════════════════════════════════════════════════════════════

┌──────────────────────────────────────────────────────────────┐
│                     NEW SEGMENT ARRIVES                       │
│  { text: "hello", start: 0.0, end: 1.5, completed: false }  │
└──────────────────────────────────────────────────────────────┘
                           │
                           ↓
              ┌────────────────────────┐
              │ Find matching segment? │
              │ (timestamp ± 100ms)    │
              └────────────────────────┘
                    │             │
          ┌─────────┴──────┐     │
          │ YES            │     │ NO
          ↓                │     ↓
   ┌─────────────┐         │   ┌──────────────────┐
   │ Is locked?  │         │   │ INSERT new       │
   └─────────────┘         │   │ segment          │
      │        │            │   │ locked = false   │
      YES      NO           │   │ version = 1      │
      ↓        ↓            │   └──────────────────┘
   ┌────┐  ┌────────┐      │           │
   │REJECT│  │UPDATE │      │           │
   │      │  │ text  │      │           │
   │      │  │version++│    │           │
   └────┘  └────────┘      │           │
                           │           │
                           └───────────┘
                                 │
                                 ↓
                    ┌────────────────────────┐
                    │ Check finalization     │
                    │ segment.end < fence?   │
                    └────────────────────────┘
                          │           │
                          YES         NO
                          ↓           ↓
                    ┌─────────┐  ┌─────────┐
                    │ locked  │  │ locked  │
                    │ = true  │  │ = false │
                    └─────────┘  └─────────┘


EXAMPLE SEQUENCE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
t=0s:   INSERT { "hello", 0.0-1.5, locked=false, v=1 }

t=1s:   UPDATE { "hello world", 0.0-2.0, locked=false, v=2 }
        ↑ Same start time, refined text

t=3s:   fence moves to 1.0s
        → Segment 0.0-2.0 end > 1.0s → still unlocked

t=5s:   fence moves to 3.0s
        → Segment 0.0-2.0 end < 3.0s → LOCK IT
        → locked=true, immutable from now on

t=7s:   Attempt UPDATE { "goodbye", 0.0-2.0, ... }
        → REJECTED (segment is locked)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 5. Query API Visual Examples

```
═══════════════════════════════════════════════════════════════════
TIMELINE AT t=7.0s (liveEdge)
═══════════════════════════════════════════════════════════════════

Segments:
[0.0-1.5] hello          locked=true   v=2
[1.5-2.8] world          locked=true   v=1
[2.8-3.5] how            locked=true   v=3
[3.5-4.2] are            locked=true   v=1
[4.2-5.0] you            locked=true   v=1
                         ↑ finalizationFence (5.0s)
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
[5.0-6.2] doing          locked=false  v=2
[6.2-7.0] fine           locked=false  v=1


QUERY: getLockedSegments()
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Returns:
[
  { text: "hello", start: 0.0, end: 1.5, locked: true },
  { text: "world", start: 1.5, end: 2.8, locked: true },
  { text: "how",   start: 2.8, end: 3.5, locked: true },
  { text: "are",   start: 3.5, end: 4.2, locked: true },
  { text: "you",   start: 4.2, end: 5.0, locked: true }
]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


QUERY: getUnlockedSegments()
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Returns:
[
  { text: "doing", start: 5.0, end: 6.2, locked: false },
  { text: "fine",  start: 6.2, end: 7.0, locked: false }
]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


QUERY: getSegmentsInRange(2.0, 5.5)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Returns segments overlapping [2.0, 5.5]:
[
  { text: "world", start: 1.5, end: 2.8, locked: true },  ← overlaps
  { text: "how",   start: 2.8, end: 3.5, locked: true },
  { text: "are",   start: 3.5, end: 4.2, locked: true },
  { text: "you",   start: 4.2, end: 5.0, locked: true },
  { text: "doing", start: 5.0, end: 6.2, locked: false }  ← overlaps
]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


QUERY: querySegments({ locked: true, minStart: 2.0, maxEnd: 4.5 })
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Returns locked segments with start >= 2.0 AND end <= 4.5:
[
  { text: "how", start: 2.8, end: 3.5, locked: true },
  { text: "are", start: 3.5, end: 4.2, locked: true }
]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 6. User Interface Mockup

```
═══════════════════════════════════════════════════════════════════
BROWSER UI WITH FENCE CONTROL
═══════════════════════════════════════════════════════════════════

┌────────────────────────────────────────────────────────────────┐
│ Streaming ASR - Real-time Transcription                        │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│ 🎙️ Recording... (7.2s)                           [Stop] [⏸️]   │
│                                                                 │
├────────────────────────────────────────────────────────────────┤
│ ⚙️ Finalization Fence Control                                  │
│                                                                 │
│ Lock Window: [────●────────] 2.0 seconds                       │
│               0.5          5.0                                  │
│                                                                 │
│ Current fence: 5.2s (liveEdge 7.2s - 2.0s)                     │
│ Locked: 5 segments | Unlocked: 2 segments                      │
│                                                                 │
│ [🔒 Lock All Now]  [🔓 Reset Fence]                            │
│                                                                 │
├────────────────────────────────────────────────────────────────┤
│ 📝 FINAL TRANSCRIPT (Locked - Safe to Copy)                    │
│                                                                 │
│ hello world how are you                                        │
│                            ↑                                    │
│                            └─ fence at 5.2s                     │
│                                                                 │
│ [📋 Copy] [💾 Download]                                         │
│                                                                 │
├────────────────────────────────────────────────────────────────┤
│ 👁️ LIVE PREVIEW (Locked + Unlocked)                            │
│                                                                 │
│ <span class="locked">hello world how are you</span>            │
│ <span class="mutable">doing fine</span>                        │
│                                                                 │
│ Legend: █ Locked (immutable)  █ Mutable (may change)           │
│                                                                 │
└────────────────────────────────────────────────────────────────┘


CSS Styling:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.locked {
  color: #065f46;
  font-weight: 600;
  background: linear-gradient(to right, #d1fae5 0%, transparent 100%);
}

.mutable {
  color: #92400e;
  font-style: italic;
  opacity: 0.8;
  background: linear-gradient(to right, #fef3c7 0%, transparent 100%);
}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 7. Performance Characteristics

```
═══════════════════════════════════════════════════════════════════
OPERATION COMPLEXITY ANALYSIS
═══════════════════════════════════════════════════════════════════

Given n = total segments

Operation                    | Time      | Space  | Notes
─────────────────────────────┼───────────┼────────┼─────────────────
ingest()                     | O(n)      | O(1)   | Linear scan to find match
getLockedSegments()          | O(1)*     | O(n)   | *Cached, rebuild on invalidation
getUnlockedSegments()        | O(1)*     | O(n)   | *Cached
getAllSegments()             | O(1)      | O(n)   | Return copy of array
getSegmentsInRange()         | O(n)      | O(k)   | Filter operation
querySegments()              | O(n)      | O(k)   | Filter with multiple predicates
setLockWindow()              | O(n)      | O(1)   | Must recompute fence + locks
lockSegmentsUpTo()           | O(n)      | O(1)   | Scan and update
reset()                      | O(1)      | O(1)   | Clear arrays
finalizeAll()                | O(n)      | O(1)   | Mark all as locked


BENCHMARK (Typical Session):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Session Duration: 1 hour
Segments: ~3,600 (1 per second average)

Operation               Time (ms)   Frequency        Total/session
────────────────────────┼───────────┼────────────────┼──────────────
ingest()                0.05        3,600 times      180ms
getLockedSegments()     0.01        1,000 times      10ms
setLockWindow()         0.5         10 times         5ms
                                                     ────────
                                                     195ms total
                                                     (negligible)


SCALING (Long Sessions):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
8 hour session:
- 28,800 segments
- ~150 bytes/segment
- Total memory: 4.3 MB

Recommendation: Archive locked segments older than 1 hour
- Move to IndexedDB or server
- Keep last 1 hour in memory
- Reduces to ~3,600 segments max
```

---

## 8. Comparison: Text-Based vs Timestamp-Based

```
═══════════════════════════════════════════════════════════════════
SCENARIO: WhisperLive Rewrites Text
═══════════════════════════════════════════════════════════════════

WhisperLive Window A outputs:
┌────────────────────────────────────────┐
│ "how old are you"                      │
│ start: 2.0s, end: 5.0s                 │
└────────────────────────────────────────┘

WhisperLive Window B outputs (model changed its mind):
┌────────────────────────────────────────┐
│ "how are you doing"                    │
│ start: 2.0s, end: 6.0s                 │
└────────────────────────────────────────┘


TEXT-BASED APPROACH (Current v3.0.7):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 1: Tokenize
  A: ["how", "old", "are", "you"]
  B: ["how", "are", "you", "doing"]

Step 2: Find longest common prefix (LCP)
  LCP(A, B) = ["how"] (length 1)

Step 3: Detect as slide (LCP ratio = 1/4 = 0.25 < threshold 0.4)
  ✓ Triggers slide rescue mechanism

Step 4: Attempt to rescue remaining tokens
  Remainder: ["old", "are", "you"]
  Check for duplicates in recent tail
  ❌ Fails if "are you" already committed

Result: 😕 Complex heuristics, may miss "old" or duplicate "are you"


TIMESTAMP-BASED APPROACH (Proposed v4.0.0):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 1: Find matching segment by timestamp
  A.start = 2.0s, A.end = 5.0s
  B.start = 2.0s, B.end = 6.0s
  Match? abs(2.0 - 2.0) < 0.1s ✓ YES

Step 2: Check if locked
  A.locked = false (in mutable zone)

Step 3: Update segment
  A.text = "how old are you" → "how are you doing"
  A.end = 5.0s → 6.0s
  A.version = 1 → 2

Result: ✅ Simple, correct, no duplicates
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


VERDICT: Timestamp-based is more robust for text rewrites
```

---

## Summary

**Key Visual Concepts:**

1. **Finalization Fence** = Boundary between immutable and mutable segments
2. **Sliding Windows** = WhisperLive processes overlapping audio chunks
3. **Timestamp Matching** = Fuzzy matching (±100ms) to handle jitter
4. **State Transitions** = Segments move from unlocked → locked
5. **Query API** = Flexible retrieval by lock status and time range
6. **UI Integration** = Visual distinction between locked/unlocked text
7. **Performance** = O(n) operations acceptable for typical sessions
8. **Robustness** = Timestamp-based > text-based for rewrites
