# Request for ChatGPT: Option A Implementation

## Decision

**I choose Option A: Final-Grace & Cross-Segment Reconciliation**

## What I Need

Please provide the complete implementation with the following:

### 1. Full TranscriptAccumulator Class

Patched methods:
- `__init__()` - Add new data structures (awaiting_final, partial_history, TTL settings)
- `add_partial()` - Update to write to partial_history ring buffer
- `add_final()` - Cross-segment reconciliation with snapshots + history
- `_force_segment_break()` - Snapshot pending tokens, don't clear them
- New helper methods for snapshot management and expiry

### 2. Configuration Parameters

Recommended tuning values:
- `K` (stability_threshold): 2 (was 3)
- `T` (forced_flush_ms): 1200-1500ms (was 2000ms)
- `max_segment_s`: Keep at 12s
- `AWAITING_FINAL_TTL_MS`: 3000-6000ms (new)
- `PARTIAL_HISTORY_WINDOW_S`: 30s (new)

### 3. Data Structures

Please implement:
```python
stable: List[token]           # Append-only truth
pending: deque[PendingToken]  # Current hypothesis
awaiting_final: deque[Snapshot{tokens, started_ms, expiry_ms}]  # Survives segment rolls
partial_history: deque[TimedText]  # Last N tokens/seconds of partials
```

### 4. Observability

Add these metrics counters:
- `late_final_hits` - Finals that matched a snapshot
- `snapshot_expired_commits` - Snapshots that timed out and auto-committed
- `orphan_rescues` - Words rescued from snapshots
- `segment_rolls` - Total segment breaks
- `words_lost_pre_fix` - (for comparison tracking)

### 5. Pytest Unit Test

Please provide a pytest that:
- Simulates the counting 1-28 scenario
- Reproduces the word loss bug with old code
- Proves **no loss of words 9, 10, 15, 17** with new code
- Tests late final scenarios (finals arriving after segment timeout)
- Tests snapshot TTL expiry behavior

### 6. Integration Notes

My current system:
- Python 3.10+ with asyncio
- RIVA 2.19.0 streaming ASR
- WebSocket bridge architecture
- Current accumulator at: `src/asr/transcript_accumulator.py`

Please make the code compatible with my existing:
- Token class: `@dataclass Token(text, confirmation_count, first_seen_time, last_seen_time)`
- Display event format: `{'stable_text': str, 'partial_suffix': str, 'is_final': bool, ...}`
- Logging: Uses Python `logging` module

## Current Code Structure

My existing `TranscriptAccumulator` has:
- `stable_text: str` - Committed transcript
- `pending_tokens: List[Token]` - Candidates for commitment
- `prev_partial: str` - For LCP optimization
- Methods: `add_partial()`, `add_final()`, `_build_display_event()`, `get_metrics()`

## Expected Behavior After Fix

When user counts 1-28:
- ✅ All numbers appear in final transcript
- ✅ No missing words (9, 10, 15, 17 captured)
- ✅ Segment breaks don't cause data loss
- ✅ Late finals (arriving 5-8 seconds after segment break) reconcile correctly
- ✅ Logs show: "✓ Late final matched snapshot from segment N, rescued M orphaned tokens"

## Test Scenario to Pass

```python
# Simulated RIVA behavior (sliding window partials + late finals)
partials = [
    "one", "one two", "two three", "three four", ...  # sliding window
]
# 12 seconds pass → segment break fires → snapshot created
# 8 seconds later → final arrives: "one two three four five six seven eight"
# Expected: All words captured, orphan detection rescues words 1-8
```

Please provide:
1. ✅ Complete `TranscriptAccumulator` class code
2. ✅ Pytest test file
3. ✅ Configuration recommendations
4. ✅ Integration instructions
5. ✅ Expected log output examples

Thank you!
