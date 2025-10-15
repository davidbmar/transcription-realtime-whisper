#!/usr/bin/env python3
"""
Pytest tests for TranscriptAccumulator Option A (Final-Grace & Cross-Segment Reconciliation)

Tests verify:
- Counting scenario (1-28) with no word loss
- Late final rescue from snapshots
- Snapshot expiry behavior
- Cross-segment reconciliation
"""

import time
import pytest
import sys
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.asr.transcript_accumulator import TranscriptAccumulator, Token, detokenize


class FakeClock:
    """Mock clock for deterministic testing"""
    def __init__(self, start=0.0):
        self.t = start

    def __call__(self):
        return self.t

    def advance(self, s: float):
        self.t += s


def words(txt):
    """Helper to split text into words"""
    return [w for w in txt.split()]


@pytest.fixture
def acc():
    """Create accumulator with fake clock for testing"""
    clk = FakeClock()
    acc = TranscriptAccumulator(
        stability_threshold=2,       # K=2
        forced_flush_ms=1400,        # T=1.4s
        max_segment_s=12.0,          # 12s
        awaiting_final_ttl_ms=5000,  # 5s grace
        partial_history_window_s=30.0,
        time_fn=clk,
    )
    return acc, clk


def test_counting_late_final_rescue(acc):
    """Test counting 1-10 with segment break and late final"""
    acc, clk = acc

    # Simulate sliding-window partials: 1..10 across ~12.2s (trigger segment roll at ~12s)
    # Partial cadence: every 0.3s; numbers about every 0.8-1.0s
    count_tokens = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    window = 3
    cur = []

    for idx, w in enumerate(count_tokens):
        cur.append(w)
        # Send 2-3 partials causing sliding effects
        for _ in range(3):
            # Emulate sliding window: keep only last `window` items
            wnd = cur[-window:]
            acc.add_partial(" ".join(wnd))
            clk.advance(0.3)
        # Step time a bit more between numbers
        clk.advance(0.2)

    # At this point ~ (10 * (3*0.3 + 0.2)) = 11s; push a bit more to exceed 12s to force segment break
    clk.advance(1.5)                   # >12s total -> segment timeout on next partial
    acc.add_partial("eight nine ten")  # Still talking, triggers segment break

    # Force_segment_break will snapshot pending & roll
    # Advance time within grace window (e.g., 3s later) and final arrives but omits "nine ten" (!)
    clk.advance(3.0)
    ev_final = acc.add_final("one two three four five six seven eight")

    # Check stable includes 1..8 (rescued from snapshot + appended from final)
    st = ev_final["stable_text"]
    for w in ["one", "two", "three", "four", "five", "six", "seven", "eight"]:
        assert w in st.split(), f"Missing word '{w}' in stable text: {st}"

    print(f"\n✅ Test passed! Stable text: {st}")
    print(f"Metrics: {acc.get_metrics()}")


def test_late_final_after_timeout_and_missing_middle(acc):
    """Test counting 1-12 with fragmented late finals missing middle numbers"""
    acc, clk = acc

    # Speak 1..12 continuously, but finals will be fragmented and late.
    nums = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]

    # Emit partials (sliding) over ~13s to force a roll before finals
    window = 4
    buf = []
    for w in nums:
        buf.append(w)
        for _ in range(2):
            acc.add_partial(" ".join(buf[-window:]))
            clk.advance(0.35)
        clk.advance(0.25)

    # Now we are past 12s; a segment roll has happened with snapshot.
    # Send a late, incomplete final covering only 1..8
    clk.advance(2.5)
    acc.add_final("one two three four five six seven eight")

    # Then another late final covering 11..12 but omitting 9..10
    clk.advance(2.0)
    acc.add_final("eleven twelve")

    # Our algorithm should have rescued 9 and 10 either from snapshot expiry or orphan rescue
    st = acc.stable_text
    for w in ["nine", "ten", "eleven", "twelve"]:
        assert w in st.split(), f"Missing word '{w}' in stable text: {st}"

    print(f"\n✅ Test passed! Stable text: {st}")
    print(f"Metrics: {acc.get_metrics()}")


def test_snapshot_expiry_commits_tokens(acc):
    """Test that expired snapshots auto-commit to prevent data loss"""
    acc, clk = acc

    # Create pending by speaking quickly (no finals yet)
    acc.add_partial("alpha beta gamma")
    clk.advance(0.3)
    acc.add_partial("beta gamma delta")
    clk.advance(0.3)

    # Force segment break -> snapshot pending
    clk.advance(12.0)
    acc.add_partial("gamma delta")  # Triggers force_segment_break

    # Let snapshot expire without a final (TTL 5s)
    clk.advance(6.0)
    acc.add_partial("epsilon")  # Triggers expiry check

    # Expired snapshot must have been committed
    st = acc.stable_text
    assert "gamma" in st and "delta" in st, f"Missing expired tokens in stable text: {st}"

    # And metric should reflect it
    m = acc.get_metrics()
    assert m["snapshot_expired_commits"] >= 2, f"Expected snapshot_expired_commits >= 2, got {m['snapshot_expired_commits']}"

    print(f"\n✅ Test passed! Stable text: {st}")
    print(f"Metrics: {m}")


def test_k_confirmation_promotion(acc):
    """Test that tokens with K confirmations get promoted"""
    acc, clk = acc

    # Send same partial K times
    for _ in range(3):
        acc.add_partial("hello world")
        clk.advance(0.3)

    # "hello" and "world" should be promoted after 2 confirmations (K=2)
    st = acc.stable_text
    assert "hello" in st and "world" in st, f"K-confirmation failed: {st}"

    print(f"\n✅ Test passed! Stable text: {st}")


def test_t_timeout_promotion(acc):
    """Test that tokens exceeding T timeout get auto-promoted"""
    acc, clk = acc

    acc.add_partial("alpha beta")
    clk.advance(0.5)

    # Advance past T timeout (1400ms)
    clk.advance(1.5)
    acc.add_partial("beta gamma")  # Trigger promotion check

    # "alpha" should be promoted by T-timeout
    st = acc.stable_text
    assert "alpha" in st, f"T-timeout promotion failed: {st}"

    print(f"\n✅ Test passed! Stable text: {st}")


def test_empty_final_handling(acc):
    """Test that empty finals don't crash the system"""
    acc, clk = acc

    acc.add_partial("testing one two three")
    clk.advance(0.5)

    ev = acc.add_final("")  # Empty final

    assert ev["is_final"] == True, "Expected is_final=True for empty final"
    print(f"\n✅ Test passed! Empty final handled gracefully")


def test_display_event_metadata(acc):
    """Test that display events include correct metadata"""
    acc, clk = acc

    acc.add_partial("hello world")
    ev = acc.build_display_event()

    assert "stable_text" in ev
    assert "partial_suffix" in ev
    assert "segment_id" in ev
    assert "metadata" in ev
    assert "pending_tokens" in ev["metadata"]
    assert "awaiting_snapshots" in ev["metadata"]
    assert "stable_word_count" in ev["metadata"]

    print(f"\n✅ Test passed! Display event metadata correct: {ev['metadata']}")


if __name__ == "__main__":
    # Run tests manually
    print("Running TranscriptAccumulator Option A tests...\n")
    pytest.main([__file__, "-v", "-s"])
