# Timestamp-Based Transcript Accumulator Design

**Version:** 4.0.0
**Date:** 2025-01-21
**Purpose:** Replace text-based deduplication with timestamp-based approach for robust WhisperLive streaming

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Concepts](#core-concepts)
3. [API Design](#api-design)
4. [State Management](#state-management)
5. [Configuration](#configuration)
6. [Usage Examples](#usage-examples)
7. [Edge Cases](#edge-cases)
8. [Migration Path](#migration-path)
9. [Performance Considerations](#performance-considerations)
10. [Testing Strategy](#testing-strategy)

---

## Architecture Overview

### The Problem

WhisperLive sends overlapping segments with absolute timestamps:
- Same text can appear in multiple messages with slightly different timestamps (±50-150ms jitter)
- Text can be completely rewritten when model refines its hypothesis
- Segments are re-sent with `completed: true` flag when finalized
- No word-level timestamps (only segment-level `start` and `end`)

### The Solution

**Timestamp-First Architecture:** Use absolute timestamps as the primary key for segments, with configurable immutability fence.

```
┌─────────────────────────────────────────────────────────────┐
│                  TRANSCRIPT ACCUMULATOR                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐         ┌──────────────┐                 │
│  │   IMMUTABLE  │         │   MUTABLE    │                 │
│  │   (Locked)   │◄────────│  (Unlocked)  │                 │
│  │              │  Fence  │              │                 │
│  │  0s ──→ 4.8s │  moves  │  4.8s ──→ 7s │                 │
│  └──────────────┘         └──────────────┘                 │
│                                                              │
│  Finalization Fence = liveEdge - lockWindow                 │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Concepts

### 1. Segment Structure

```typescript
interface Segment {
  start: number;           // Absolute timestamp (seconds) - PRIMARY KEY
  end: number;             // Absolute timestamp (seconds)
  text: string;            // Transcript text
  locked: boolean;         // Immutability flag
  completed: boolean;      // WhisperLive finalization flag
  version: number;         // Refinement counter
  firstSeenAt: number;     // Wall clock time (for debugging)
  lastUpdatedAt: number;   // Wall clock time
}
```

### 2. Finalization Fence

**Definition:** The boundary between immutable (locked) and mutable (unlocked) segments.

```
Timeline:
0s ────────────────────────── liveEdge (7.0s)
                              │
    ├─────────────┤ lockWindow (2.0s)
    │
    finalizationFence (5.0s)
    │
    └──── Everything before this is LOCKED
```

**Calculation:**
```typescript
finalizationFence = liveEdge - lockWindow
```

**Rules:**
- Any segment with `end < finalizationFence` → `locked = true`
- Locked segments are **immutable** (text/timing cannot change)
- Fence moves forward as new audio arrives

### 3. Timestamp Matching

**Problem:** WhisperLive sends timestamps with small jitter (±50-150ms)

**Solution:** Fuzzy matching with configurable tolerance

```typescript
function timestampsMatch(t1: number, t2: number, tolerance = 0.1): boolean {
  return Math.abs(t1 - t2) <= tolerance;
}

function segmentsMatch(s1: Segment, s2: Segment): boolean {
  return timestampsMatch(s1.start, s2.start) &&
         timestampsMatch(s1.end, s2.end);
}
```

### 4. State Transitions

```
NEW SEGMENT arrives
       │
       ├─► Is there a matching segment (same timestamps ±tolerance)?
       │   │
       │   YES ─► Is it locked?
       │   │      │
       │   │      YES ─► REJECT (immutable)
       │   │      NO  ─► UPDATE text, version++
       │   │
       │   NO ─► INSERT new segment
       │
       └─► Is segment.end < finalizationFence?
           │
           YES ─► locked = true
           NO  ─► locked = false
```

---

## API Design

### Constructor

```typescript
class TimestampTranscriptAccumulator {
  constructor(config?: AccumulatorConfig);
}

interface AccumulatorConfig {
  // Finalization fence configuration
  lockWindow: number;           // Default: 2.0 seconds

  // Timestamp matching
  timestampTolerance: number;   // Default: 0.1 seconds (100ms)

  // Debugging
  debug: boolean;               // Default: false
  logPrefix: string;            // Default: '[TimestampAccumulator]'
}
```

### Core Methods

#### 1. Ingest Segment

```typescript
/**
 * Ingest a new segment from WhisperLive
 * Returns metadata about what happened
 */
ingest(segment: WhisperLiveSegment): IngestResult

interface WhisperLiveSegment {
  text: string;
  start: number;
  end: number;
  completed: boolean;
}

interface IngestResult {
  action: 'inserted' | 'updated' | 'rejected' | 'duplicate';
  reason?: string;
  segment?: Segment;
  previousVersion?: Segment;
}
```

#### 2. Query Methods (The Key Feature)

```typescript
/**
 * Get locked (immutable) segments only
 * Use for final transcript display
 */
getLockedSegments(): Segment[]

/**
 * Get unlocked (mutable) segments only
 * Use for "live preview" display
 */
getUnlockedSegments(): Segment[]

/**
 * Get all segments (locked + unlocked)
 */
getAllSegments(): Segment[]

/**
 * Query segments by time range
 */
getSegmentsInRange(startTime: number, endTime: number): Segment[]

/**
 * Get segments by lock status and time range
 */
querySegments(query: SegmentQuery): Segment[]

interface SegmentQuery {
  locked?: boolean;           // Filter by lock status
  minStart?: number;          // Minimum start time
  maxStart?: number;          // Maximum start time
  minEnd?: number;            // Minimum end time
  maxEnd?: number;            // Maximum end time
  minVersion?: number;        // Minimum refinement count
}
```

#### 3. Fence Control Methods

```typescript
/**
 * Get current finalization fence position
 */
getFinalizationFence(): number

/**
 * Manually adjust the lock window
 * Returns new fence position
 */
setLockWindow(seconds: number): number

/**
 * Get current live edge (rightmost segment end)
 */
getLiveEdge(): number

/**
 * Manually lock segments up to a specific time
 * Useful for "commit now" button in UI
 */
lockSegmentsUpTo(timestamp: number): number  // returns count locked
```

#### 4. Text Extraction Methods

```typescript
/**
 * Get finalized transcript (locked segments only)
 */
getTranscript(): string

/**
 * Get full preview (locked + unlocked segments)
 */
getPreviewText(): string

/**
 * Get transcript with segment markers (for debugging)
 */
getAnnotatedTranscript(): string
// Example output:
// "[0.0-1.5|L|v2] hello [1.5-2.8|L|v1] world [2.8-3.5|U|v3] how"
//   ^start ^end ^Locked/Unlocked ^version
```

#### 5. State Management

```typescript
/**
 * Reset accumulator for new recording session
 */
reset(): void

/**
 * Force finalization of all mutable segments
 * Call when recording stops
 */
finalizeAll(): number  // returns count of segments finalized

/**
 * Get accumulator statistics
 */
getStats(): AccumulatorStats

interface AccumulatorStats {
  totalSegments: number;
  lockedSegments: number;
  unlockedSegments: number;
  finalizationFence: number;
  liveEdge: number;
  oldestSegment: number;
  newestSegment: number;
  averageSegmentDuration: number;
  totalDuration: number;
}
```

---

## State Management

### Internal Data Structures

```typescript
class TimestampTranscriptAccumulator {
  private segments: Segment[] = [];
  private config: Required<AccumulatorConfig>;

  // Performance optimization: maintain sorted indices
  private lockedCache: Segment[] = [];
  private unlockedCache: Segment[] = [];
  private cacheValid: boolean = false;

  // State tracking
  private liveEdge: number = 0;
  private finalizationFence: number = 0;

  // ... methods
}
```

### Cache Invalidation Strategy

```typescript
private invalidateCache(): void {
  this.cacheValid = false;
}

private rebuildCache(): void {
  if (this.cacheValid) return;

  this.lockedCache = this.segments.filter(s => s.locked);
  this.unlockedCache = this.segments.filter(s => !s.locked);

  // Keep sorted by start time
  this.lockedCache.sort((a, b) => a.start - b.start);
  this.unlockedCache.sort((a, b) => a.start - b.start);

  this.cacheValid = true;
}

getLockedSegments(): Segment[] {
  this.rebuildCache();
  return [...this.lockedCache];  // Return copy to prevent mutation
}
```

---

## Configuration

### Default Configuration

```typescript
const DEFAULT_CONFIG: Required<AccumulatorConfig> = {
  lockWindow: 2.0,              // 2 seconds behind live edge
  timestampTolerance: 0.1,      // 100ms jitter tolerance
  debug: false,
  logPrefix: '[TimestampAccumulator]'
};
```

### Runtime Configuration Changes

```typescript
// Example: User wants to see more "live" text before locking
accumulator.setLockWindow(3.5);  // Increase to 3.5 seconds

// Example: User wants aggressive locking for stable output
accumulator.setLockWindow(0.5);  // Lock everything 0.5s behind edge
```

---

## Usage Examples

### Example 1: Basic Usage

```typescript
// Initialize
const accumulator = new TimestampTranscriptAccumulator({
  lockWindow: 2.0,
  debug: true
});

// Ingest WhisperLive messages
ws.onmessage = (event) => {
  const data = JSON.parse(event.data);

  if (data.segments) {
    for (const segment of data.segments) {
      const result = accumulator.ingest({
        text: segment.text,
        start: segment.start,
        end: segment.end,
        completed: segment.completed
      });

      console.log(`${result.action}: ${segment.text.substring(0, 30)}`);
    }
  }

  // Update UI
  updateFinalTranscript(accumulator.getTranscript());
  updateLivePreview(accumulator.getPreviewText());
};

// When recording stops
stopBtn.onclick = () => {
  accumulator.finalizeAll();
  const final = accumulator.getTranscript();
  saveToDatabase(final);
};
```

### Example 2: Querying Different States

```typescript
// Show only finalized text in "AI Assistant" panel
function updateAIPanel() {
  const locked = accumulator.getLockedSegments();
  const text = locked.map(s => s.text).join(' ');
  aiPanel.innerHTML = text.replace(/\n/g, '<br>');
}

// Show live preview with color coding
function updateLivePreview() {
  const locked = accumulator.getLockedSegments();
  const unlocked = accumulator.getUnlockedSegments();

  const lockedHTML = locked
    .map(s => `<span class="locked">${s.text}</span>`)
    .join(' ');

  const unlockedHTML = unlocked
    .map(s => `<span class="mutable">${s.text}</span>`)
    .join(' ');

  previewDiv.innerHTML = lockedHTML + ' ' + unlockedHTML;
}
```

### Example 3: Time-Range Queries

```typescript
// Get transcript for a specific time range (e.g., for video clip)
function getTranscriptForClip(startTime: number, endTime: number): string {
  const segments = accumulator.getSegmentsInRange(startTime, endTime);
  return segments.map(s => s.text).join(' ');
}

// Example: Get transcript from 30s to 45s
const clipText = getTranscriptForClip(30.0, 45.0);

// Get only finalized segments in a time range
const finalized = accumulator.querySegments({
  locked: true,
  minStart: 30.0,
  maxEnd: 45.0
});
```

### Example 4: Dynamic Fence Adjustment

```typescript
// User slider to control how much "live preview" to show
fenceSlider.oninput = (e) => {
  const lockWindow = parseFloat(e.target.value);  // 0.5 - 5.0 seconds
  accumulator.setLockWindow(lockWindow);

  const fence = accumulator.getFinalizationFence();
  fenceLabel.textContent = `Locking ${lockWindow}s behind live edge (fence: ${fence.toFixed(1)}s)`;

  updateUI();
};

// "Commit Now" button - lock everything immediately
commitBtn.onclick = () => {
  const count = accumulator.lockSegmentsUpTo(accumulator.getLiveEdge());
  alert(`Locked ${count} segments`);
};
```

### Example 5: Debugging with Annotated Output

```typescript
// Show detailed segment info for debugging
function showDebugInfo() {
  console.log(accumulator.getAnnotatedTranscript());

  const stats = accumulator.getStats();
  console.table(stats);

  // Example output:
  // [0.0-1.5|L|v2] hello [1.5-2.8|L|v1] world [2.8-3.5|U|v3] how
  //
  // ┌──────────────────────────┬────────┐
  // │ totalSegments            │ 12     │
  // │ lockedSegments          │ 8      │
  // │ unlockedSegments        │ 4      │
  // │ finalizationFence       │ 5.2    │
  // │ liveEdge                │ 7.2    │
  // │ totalDuration           │ 7.2    │
  // └──────────────────────────┴────────┘
}
```

---

## Edge Cases

### 1. Duplicate Finals

**Scenario:** WhisperLive re-sends completed segments in every message

```typescript
Message 1:
{ segments: [
  { text: "hello", start: 0.0, end: 1.5, completed: true }
]}

Message 2:
{ segments: [
  { text: "hello", start: 0.0, end: 1.5, completed: true },  ← Duplicate!
  { text: "world", start: 1.5, end: 2.8, completed: true }
]}
```

**Handling:**
```typescript
ingest(segment) {
  // Check if segment already exists with same timestamp
  const existing = this.findMatchingSegment(segment);

  if (existing && existing.locked) {
    return { action: 'rejected', reason: 'Already locked (immutable)' };
  }

  if (existing && existing.text === segment.text) {
    return { action: 'duplicate', reason: 'Same timestamp and text' };
  }

  // ... continue processing
}
```

### 2. Text Rewrites in Locked Region

**Scenario:** WhisperLive sends a revised segment that overlaps locked region

```typescript
Existing (locked):
{ start: 2.0, end: 4.0, text: "how old are you", locked: true }

New segment:
{ start: 2.0, end: 5.0, text: "how are you doing", completed: false }
```

**Handling:**
```typescript
ingest(segment) {
  const fence = this.getFinalizationFence();

  // Segment overlaps locked region
  if (segment.start < fence) {
    const existing = this.findMatchingSegment(segment);

    if (existing && existing.locked) {
      console.warn(`⚠️ Rejecting update to locked segment at ${segment.start}s`);
      return { action: 'rejected', reason: 'Overlaps immutable region' };
    }
  }

  // ... continue
}
```

### 3. Time Regression

**Scenario:** Segment arrives with `start` time before last segment

```typescript
Existing:
{ start: 5.0, end: 6.5, text: "doing fine" }

New (regression):
{ start: 3.0, end: 4.5, text: "are you" }  ← Earlier than expected!
```

**Handling:**
```typescript
ingest(segment) {
  // Check if this is a late-arriving segment
  if (segment.start < this.liveEdge - this.config.lockWindow) {
    console.warn(`⏮️ Late segment at ${segment.start}s (live edge: ${this.liveEdge}s)`);

    // Allow if not overlapping locked region
    if (segment.end < this.finalizationFence) {
      console.warn(`❌ Rejected: segment ${segment.start}-${segment.end}s is before fence ${this.finalizationFence}s`);
      return { action: 'rejected', reason: 'Before finalization fence' };
    }
  }

  // ... continue
}
```

### 4. Overlapping Segments

**Scenario:** Two segments with different timestamps overlap in time

```typescript
Segment A: [2.0 ───────── 5.0]  "how are you"
Segment B:      [3.0 ──────── 6.0]  "are you doing"
```

**Handling:**
```typescript
// Allow overlaps - this is normal in sliding window architecture
// Just track them separately if timestamps differ

ingest(segment) {
  const overlapping = this.segments.filter(s =>
    s.start < segment.end && s.end > segment.start
  );

  if (overlapping.length > 0 && this.config.debug) {
    console.log(`ℹ️ ${overlapping.length} overlapping segments at ${segment.start}s`);
  }

  // Check if any overlap is an exact match (same timestamps)
  const exactMatch = overlapping.find(s => this.segmentsMatch(s, segment));

  if (exactMatch) {
    return this.updateSegment(exactMatch, segment);
  } else {
    return this.insertSegment(segment);
  }
}
```

---

## Migration Path

### Phase 1: Parallel Implementation

```typescript
// Keep old accumulator running
const oldAccumulator = new TranscriptAccumulator();
const newAccumulator = new TimestampTranscriptAccumulator({ debug: true });

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);

  for (const segment of data.segments) {
    // Old path (text-based)
    oldAccumulator.ingestPartial(segment.text);
    if (segment.completed) oldAccumulator.ingestFinal(segment.text);

    // New path (timestamp-based)
    newAccumulator.ingest(segment);
  }

  // Compare outputs
  const oldText = oldAccumulator.getTranscript();
  const newText = newAccumulator.getTranscript();

  if (oldText !== newText) {
    console.warn('⚠️ Mismatch detected:', { oldText, newText });
  }
};
```

### Phase 2: Switch Over

```typescript
// Remove old accumulator
const accumulator = new TimestampTranscriptAccumulator();

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);

  for (const segment of data.segments) {
    accumulator.ingest(segment);
  }

  updateUI();
};
```

---

## Performance Considerations

### Time Complexity

| Operation | Complexity | Notes |
|-----------|------------|-------|
| `ingest()` | O(n) | Linear scan to find matching segment |
| `getLockedSegments()` | O(1) | Cached, rebuilt on invalidation |
| `getUnlockedSegments()` | O(1) | Cached, rebuilt on invalidation |
| `getSegmentsInRange()` | O(n) | Filter operation |
| `setLockWindow()` | O(n) | Must recompute fence and update locks |

### Optimization Strategies

1. **Spatial Index:** Use interval tree for O(log n) range queries
2. **Lazy Fence Updates:** Only recompute when accessed
3. **Incremental Locking:** Track last fence position, only lock new segments

```typescript
// Optimized fence update
private updateFinalizationFence(): void {
  const oldFence = this.finalizationFence;
  const newFence = this.liveEdge - this.config.lockWindow;

  if (newFence === oldFence) return;  // No change

  this.finalizationFence = newFence;

  // Only process segments between old and new fence
  const toUpdate = this.segments.filter(s =>
    s.end >= oldFence && s.end < newFence && !s.locked
  );

  toUpdate.forEach(s => {
    s.locked = true;
    this.invalidateCache();
  });
}
```

### Memory Considerations

- **Typical session:** 1 hour audio ≈ 3600 segments (1 per second average)
- **Memory per segment:** ~150 bytes → 540 KB total
- **No cleanup needed** for typical sessions
- **Long sessions (>4 hours):** Consider pruning very old locked segments

---

## Testing Strategy

### Unit Tests

```typescript
describe('TimestampTranscriptAccumulator', () => {
  test('should insert new segment', () => {
    const acc = new TimestampTranscriptAccumulator();
    const result = acc.ingest({
      text: 'hello',
      start: 0.0,
      end: 1.5,
      completed: false
    });

    expect(result.action).toBe('inserted');
    expect(acc.getAllSegments()).toHaveLength(1);
  });

  test('should reject duplicate with same timestamp', () => {
    const acc = new TimestampTranscriptAccumulator();

    acc.ingest({ text: 'hello', start: 0.0, end: 1.5, completed: true });
    const result = acc.ingest({ text: 'hello', start: 0.0, end: 1.5, completed: true });

    expect(result.action).toBe('duplicate');
  });

  test('should update unlocked segment', () => {
    const acc = new TimestampTranscriptAccumulator();

    acc.ingest({ text: 'how old are', start: 2.0, end: 4.0, completed: false });
    const result = acc.ingest({ text: 'how are you', start: 2.0, end: 4.0, completed: false });

    expect(result.action).toBe('updated');
    expect(result.segment.text).toBe('how are you');
    expect(result.segment.version).toBe(2);
  });

  test('should reject updates to locked segments', () => {
    const acc = new TimestampTranscriptAccumulator({ lockWindow: 0.5 });

    acc.ingest({ text: 'hello', start: 0.0, end: 1.5, completed: true });
    acc.ingest({ text: 'world', start: 1.5, end: 3.0, completed: false });  // Moves fence

    const result = acc.ingest({ text: 'goodbye', start: 0.0, end: 1.5, completed: false });

    expect(result.action).toBe('rejected');
    expect(result.reason).toContain('immutable');
  });

  test('should handle sliding finalization fence', () => {
    const acc = new TimestampTranscriptAccumulator({ lockWindow: 2.0 });

    acc.ingest({ text: 'hello', start: 0.0, end: 1.5, completed: false });
    expect(acc.getLockedSegments()).toHaveLength(0);

    acc.ingest({ text: 'world', start: 1.5, end: 3.5, completed: false });
    expect(acc.getLockedSegments()).toHaveLength(1);  // 'hello' is now locked
  });

  test('should handle timestamp jitter', () => {
    const acc = new TimestampTranscriptAccumulator({ timestampTolerance: 0.1 });

    acc.ingest({ text: 'hello', start: 2.000, end: 3.000, completed: false });
    const result = acc.ingest({ text: 'hello', start: 2.050, end: 3.050, completed: false });

    expect(result.action).toBe('updated');  // Within 100ms tolerance
  });
});
```

### Integration Tests

```typescript
describe('WhisperLive Integration', () => {
  test('should handle typical WhisperLive message sequence', () => {
    const acc = new TimestampTranscriptAccumulator();

    // Message 1: First partial
    acc.ingest({ text: 'hello world', start: 0.0, end: 2.0, completed: false });

    // Message 2: Refinement + new partial
    acc.ingest({ text: 'hello world', start: 0.0, end: 2.0, completed: true });
    acc.ingest({ text: 'how are you', start: 2.0, end: 4.0, completed: false });

    // Message 3: More partials
    acc.ingest({ text: 'hello world', start: 0.0, end: 2.0, completed: true });  // Duplicate
    acc.ingest({ text: 'how are you', start: 2.0, end: 4.0, completed: true });
    acc.ingest({ text: 'doing fine', start: 4.0, end: 6.0, completed: false });

    expect(acc.getTranscript()).toBe('hello world how are you');
    expect(acc.getPreviewText()).toBe('hello world how are you doing fine');
  });
});
```

---

## Open Questions for ChatGPT Review

1. **Timestamp Tolerance:** Is 100ms the right default? Should it be configurable per-segment based on duration?

2. **Overlapping Segments:** Should we merge overlapping segments, or keep them separate? What's the best UX?

3. **Lock Window Default:** Is 2.0 seconds reasonable? Should it adapt based on speech rate?

4. **Version Tracking:** Should we expose full version history, or just current + previous?

5. **Performance:** For very long sessions (8+ hours), should we implement segment pruning/archival?

6. **Word-Level Timing:** If WhisperLive adds word-level timestamps in the future, how should we integrate?

7. **Concurrent Updates:** Should we handle race conditions if multiple WebSocket messages arrive simultaneously?

8. **State Persistence:** Should we support serialization/deserialization for session recovery?

---

## Summary

This design provides:

✅ **Robust timestamp-based deduplication** - No more text-matching heuristics
✅ **Flexible querying** - Get locked, unlocked, or time-range filtered segments
✅ **Configurable immutability** - User-adjustable finalization fence
✅ **Production-ready** - Handles all edge cases (duplicates, rewrites, jitter)
✅ **Performant** - Cached queries, incremental updates
✅ **Testable** - Clear contracts, comprehensive test strategy

**Next Steps:**
1. Review this design with ChatGPT for validation
2. Implement `TimestampTranscriptAccumulator` class
3. Add UI controls for fence adjustment
4. Run parallel with existing implementation
5. Switch over after validation period
