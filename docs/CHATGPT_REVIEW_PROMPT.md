# ChatGPT Review Prompt

**Copy this entire message to ChatGPT for validation**

---

Hi ChatGPT,

I'm building a real-time speech transcription system using WhisperLive (Whisper-based streaming ASR). I need you to review a design for a timestamp-based transcript accumulator with configurable immutability.

## Background

**Current Problem:**
- WhisperLive sends overlapping audio segments with absolute timestamps
- Same text can appear multiple times with slightly different timestamps (±50-150ms jitter)
- Model can completely rewrite text when it refines its hypothesis
- Our current text-based deduplication (v3.0.7) uses token matching, which breaks on rewrites

**Proposed Solution:**
- Use timestamps as primary key instead of text
- Implement a "finalization fence" that separates immutable (locked) from mutable (unlocked) segments
- Support querying both locked and unlocked segments
- Allow dynamic adjustment of the fence position

## Documents to Review

I have three documents for you to review:

### 1. Design Document (TIMESTAMP_ACCUMULATOR_DESIGN.md)

This contains:
- Architecture overview
- Core concepts (segment structure, finalization fence, timestamp matching)
- Complete API design with all methods
- State management strategy
- Configuration options
- Usage examples
- Edge cases (duplicates, rewrites, overlaps)
- Migration path from current implementation
- Performance analysis
- Testing strategy

**Key Features:**
- `getLockedSegments()` - Returns immutable segments safe for display/export
- `getUnlockedSegments()` - Returns mutable segments (live preview)
- `setLockWindow(seconds)` - Adjust how far behind live edge to lock
- `lockSegmentsUpTo(timestamp)` - Manual locking for "commit now" button
- Fuzzy timestamp matching (±100ms tolerance)
- Version tracking for each segment

### 2. Visual Guide (TIMESTAMP_ACCUMULATOR_VISUAL.md)

This contains:
- ASCII diagrams showing finalization fence concept
- Sliding window behavior visualization
- Timestamp matching examples with jitter
- State transition flowchart
- Query API examples
- UI mockup showing locked vs unlocked segments
- Performance benchmarks
- Comparison: text-based vs timestamp-based approaches

### 3. Review Questions (CHATGPT_REVIEW_QUESTIONS.md)

This contains 10 categories of questions:
1. Architecture & Approach
2. State Management
3. Edge Cases & Conflict Resolution
4. API Design
5. Performance Optimization
6. Configuration & Tuning
7. Testing & Validation
8. User Experience
9. Future-Proofing
10. Production Readiness

## What I Need from You

Please:

1. **Validate the overall architecture** - Is using timestamps as primary key sound?

2. **Identify critical issues** - What edge cases or failure modes am I missing?

3. **Review the API design** - Is the query interface intuitive and complete?

4. **Assess performance** - Are O(n) operations acceptable? Should I use trees instead?

5. **Answer the key questions:**
   - What should `lockWindow` default be (currently 2.0 seconds)?
   - How should I handle overlapping segments with different timestamps?
   - Should I support adaptive fence based on speech rate/confidence?
   - Is 100ms timestamp tolerance reasonable?
   - What's the best conflict resolution when rewrites overlap the fence?

6. **Suggest improvements** - What patterns from streaming systems, CRDTs, or real-time databases would help?

7. **Validate the testing strategy** - What additional test cases should I add?

## Specific Concerns

**Concern 1: Timestamp Jitter**
WhisperLive sends timestamps with ±50-150ms jitter. I'm using 100ms tolerance for matching. Is this:
- Too tight (will create duplicate segments)?
- Too loose (will merge distinct segments)?
- Should it be adaptive based on segment duration?

**Concern 2: Overlapping Segments**
When two segments overlap in time but have different timestamps:
```
Segment A: [2.0s ───── 5.0s] "how are you"
Segment B:      [3.0s ───── 6.0s] "are you doing"
```
Should I:
- Keep both (current approach)
- Merge them
- Reject one based on confidence/length?

**Concern 3: Lock Window Default**
Is 2.0 seconds reasonable for the default lock window? Trade-offs:
- Smaller (0.5s): More stable output, less refinement
- Larger (5.0s): More refinement, unstable preview

Should it adapt based on:
- Speech rate (faster → smaller window)
- Model confidence (low → larger window)
- Audio quality (noisy → larger window)

**Concern 4: State at Fence Boundary**
When a rewrite overlaps the finalization fence:
```
Locked:   [0s ───── 5.0s] (fence)
New:         [4.5s ─────── 7.0s]  ← Overlaps locked region!
```
Should I:
- Reject entire segment (current approach)
- Accept unlocked portion [5.0-7.0], truncate locked portion
- Force-unlock [4.5-5.0] to allow update (dangerous!)

**Concern 5: Long Sessions**
For 8+ hour recordings:
- ~28,800 segments
- ~4.3 MB memory
- O(n) operations become slower

Should I implement segment archival? E.g., move locked segments older than 1 hour to IndexedDB?

## Context: WhisperLive Message Format

WhisperLive sends WebSocket messages like:

```json
{
  "segments": [
    {
      "text": "hello world how are you",
      "start": 0.0,
      "end": 5.2,
      "completed": false
    }
  ]
}
```

Later messages re-send previous segments with `completed: true`:

```json
{
  "segments": [
    {
      "text": "hello world how are you",
      "start": 0.0,
      "end": 5.2,
      "completed": true
    },
    {
      "text": "doing fine today",
      "start": 5.2,
      "end": 8.0,
      "completed": false
    }
  ]
}
```

## Success Criteria

The design should:
- ✅ Handle text rewrites robustly (no duplicates)
- ✅ Support querying locked vs unlocked segments
- ✅ Allow dynamic fence adjustment (user slider)
- ✅ Perform well for 1-8 hour sessions
- ✅ Be simple enough to maintain
- ✅ Be testable with clear invariants

## Your Mission

Please review all three documents and provide:
1. High-level validation or major concerns
2. Specific answers to the 5 concerns above
3. Recommendations for the 10 question categories in CHATGPT_REVIEW_QUESTIONS.md
4. Any additional patterns or approaches I should consider

Be critical! I want to catch issues before implementation.

Thank you!
