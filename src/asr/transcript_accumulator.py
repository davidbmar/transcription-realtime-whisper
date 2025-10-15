#!/usr/bin/env python3
"""
Server-Side Transcript Accumulator with Final-Grace & Cross-Segment Reconciliation (Option A)
Handles RIVA's sliding-window partials and late/incomplete finals to prevent word loss

Key Features:
- K-confirmation + T-forced-flush for pending tokens
- Snapshot buffer (awaiting_final) survives segment breaks with TTL
- Cross-segment reconciliation: late finals can claim snapshots
- Partial history ring buffer for additional context
- Orphan detection rescues words RIVA drops from finals
"""

from __future__ import annotations
from dataclasses import dataclass
from collections import deque
from typing import Deque, List, Optional, Tuple, Dict, Callable
import logging
import re
import time

logger = logging.getLogger(__name__)

# ---- External compatibility ----
@dataclass
class Token:
    """Represents a word/token with stability metadata"""
    text: str
    confirmation_count: int
    first_seen_time: float  # seconds (time.monotonic())
    last_seen_time: float   # seconds

# ---- Internal helper types ----
@dataclass
class Snapshot:
    """Snapshot of pending tokens at segment break, awaiting final reconciliation"""
    tokens: List[Token]
    started_ms: int
    expiry_ms: int
    segment_id: int

@dataclass
class TimedText:
    """Timestamped partial text for history buffer"""
    ts_ms: int
    tokens: List[str]

# ---- Tokenization helpers ----
_TOKENIZER = re.compile(r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)?|[^\sA-Za-z0-9]")

def tokenize(text: str) -> List[str]:
    """Tokenize text into words and punctuation"""
    return _TOKENIZER.findall(text or "")

def detokenize(tokens: List[str]) -> str:
    """Reconstruct text from tokens with smart spacing"""
    out = []
    for tok in tokens:
        if not out:
            out.append(tok)
        elif re.match(r"^[^\w\s]$", tok):
            out[-1] = out[-1] + tok
        else:
            out.append(" " + tok)
    return "".join(out)

def lcp_len(a: List[str], b: List[str]) -> int:
    """Compute longest common prefix length"""
    i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    return i


class TranscriptAccumulator:
    """
    Server-side authoritative accumulator resilient to RIVA sliding-window partials and late/incomplete finals.

    Key ideas:
      - Partials are replace-all hypotheses: maintain `pending` with K-confirmation (K) and aging (T)
      - Finals are per-utterance: reconcile against stable tail + cross-segment snapshot
        (`awaiting_final`) + current pending + recent partial_history
      - Segment timeouts DO NOT DROP EVIDENCE: snapshot pending into `awaiting_final` with TTL

    Public methods:
      add_partial(text: str, now_ms: Optional[int] = None) -> Dict
      add_final(text: str, now_ms: Optional[int] = None) -> Dict
      force_segment_break(now_ms: Optional[int] = None) -> None
      build_display_event() -> Dict
      get_metrics() -> Dict[str, int]
      stable_text (property): str
    """

    def __init__(
        self,
        stability_threshold: int = 2,       # K (recommend 2 for fast speech)
        forced_flush_ms: int = 1400,        # T (1200–1500ms)
        max_segment_s: float = 12.0,        # segment timeout, but we snapshot (don't drop)
        awaiting_final_ttl_ms: int = 5000,  # 3000–6000ms grace
        partial_history_window_s: float = 30.0,
        deduplication_enabled: bool = True,  # Enable deduplication filter
        deduplication_window_size: int = 30,  # Words to check for duplicates
        time_fn: Callable[[], float] = time.monotonic,
        logger_: Optional[logging.Logger] = None,
    ):
        self.log = logger_ or logger
        self.K = stability_threshold
        self.T_ms = forced_flush_ms
        self.max_segment_ms = int(max_segment_s * 1000)
        self.awaiting_final_ttl_ms = awaiting_final_ttl_ms
        self.partial_history_window_ms = int(partial_history_window_s * 1000)
        self.dedup_enabled = deduplication_enabled
        self.dedup_window_size = deduplication_window_size
        self.time_fn = time_fn  # returns seconds (monotonic)

        # Data structures
        self._stable: List[str] = []                         # append-only truth
        self.pending_tokens: Deque[Token] = deque()          # current hypothesis (left-to-right)
        self.awaiting_final: Deque[Snapshot] = deque()       # cross-segment reconciliation buffer
        self.partial_history: Deque[TimedText] = deque()     # small ring of recent partials

        # Segment tracking
        self.segment_id: int = 0
        self.segment_started_ms: Optional[int] = None

        # Observability counters
        self._metrics: Dict[str, int] = {
            "late_final_hits": 0,
            "snapshot_expired_commits": 0,
            "orphan_rescues": 0,
            "segment_rolls": 0,
            "words_lost_pre_fix": 0,   # carry-over tracker if needed
            "total_partials": 0,
            "total_finals": 0,
            "tokens_committed_by_stability": 0,
            "tokens_committed_by_final": 0,
            "tokens_committed_by_flush": 0,
            "dedup_full_blocks": 0,      # Full duplicate sequences blocked
            "dedup_partial_overlaps": 0,  # Partial overlaps removed
            "dedup_tokens_removed": 0,    # Total tokens removed by dedup
        }

        self.log.info(
            f"TranscriptAccumulator v2.6.0 (Option A + Dedup) initialized: K={stability_threshold}, "
            f"T={forced_flush_ms}ms, max_segment={max_segment_s}s, TTL={awaiting_final_ttl_ms}ms, "
            f"dedup={'enabled' if deduplication_enabled else 'disabled'} (window={deduplication_window_size})"
        )

    # ---------- properties ----------
    @property
    def stable_text(self) -> str:
        """Get stable committed text"""
        return detokenize(self._stable)

    # ---------- time helpers ----------
    def _now_ms(self) -> int:
        """Get current time in milliseconds"""
        return int(self.time_fn() * 1000)

    def _ensure_segment_started(self, now_ms: Optional[int] = None):
        """Initialize segment start time if not set"""
        if self.segment_started_ms is None:
            self.segment_started_ms = self._now_ms() if now_ms is None else now_ms

    # ---------- metrics ----------
    def get_metrics(self) -> Dict[str, int]:
        """Get accumulator performance metrics"""
        return dict(self._metrics)

    # ---------- display ----------
    def build_display_event(self, is_final: bool = False) -> Dict:
        """Build display event for client"""
        partial_suffix = detokenize([t.text for t in self.pending_tokens])
        return {
            "type": "display",  # Required for client-side routing
            "stable_text": self.stable_text,
            "partial_suffix": partial_suffix,
            "is_final": is_final,
            "segment_id": self.segment_id,
            "metadata": {
                "pending_tokens": len(self.pending_tokens),
                "awaiting_snapshots": len(self.awaiting_final),
                "stable_word_count": len(self._stable),
            }
        }

    # ---------- partial history ----------
    def _record_partial_history(self, tokens: List[str], now_ms: int):
        """Record partial in history ring buffer for late-final context"""
        self.partial_history.append(TimedText(ts_ms=now_ms, tokens=list(tokens)))
        cutoff = now_ms - self.partial_history_window_ms
        while self.partial_history and self.partial_history[0].ts_ms < cutoff:
            self.partial_history.popleft()

    # ---------- pending helpers ----------
    def _promote_leftmost_ready(self, now_ms: int) -> int:
        """Promote leftmost pending tokens that meet K or T thresholds"""
        promoted = 0
        batch_to_commit = []
        commit_reasons = []

        # Collect tokens ready for promotion
        while self.pending_tokens:
            tok = self.pending_tokens[0]
            age_ms = int((self.time_fn() - tok.first_seen_time) * 1000)
            if tok.confirmation_count >= self.K:
                batch_to_commit.append(tok.text)
                commit_reasons.append(f"K-confirmation (count={tok.confirmation_count})")
                self.pending_tokens.popleft()
                self._metrics["tokens_committed_by_stability"] += 1
            elif age_ms >= self.T_ms:
                batch_to_commit.append(tok.text)
                commit_reasons.append(f"T-timeout (age={age_ms}ms)")
                self.pending_tokens.popleft()
                self._metrics["tokens_committed_by_flush"] += 1
            else:
                break

        # Apply deduplication before committing
        if batch_to_commit:
            filtered_tokens = self._deduplicate_before_commit(batch_to_commit)
            for token in filtered_tokens:
                self._stable.append(token)
                promoted += 1

            # Log what was filtered out
            if len(filtered_tokens) < len(batch_to_commit):
                self.log.debug(f"  Dedup filtered: {len(batch_to_commit)} → {len(filtered_tokens)} tokens")

            # Log remaining tokens
            for i, token in enumerate(filtered_tokens):
                if i < len(commit_reasons):
                    self.log.debug(f"  ✓ Promoted by {commit_reasons[i]}: '{token}'")

        return promoted

    # ---------- snapshots ----------
    def _snapshot_pending(self, now_ms: int):
        """Snapshot pending tokens for cross-segment reconciliation"""
        if not self.pending_tokens:
            return
        snap_tokens = [Token(t.text, t.confirmation_count, t.first_seen_time, t.last_seen_time)
                       for t in self.pending_tokens]
        snap = Snapshot(
            tokens=snap_tokens,
            started_ms=now_ms,
            expiry_ms=now_ms + self.awaiting_final_ttl_ms,
            segment_id=self.segment_id
        )
        self.awaiting_final.append(snap)
        self.log.info(f"📸 Snapshotted {len(snap_tokens)} pending tokens for late-final reconciliation (seg {self.segment_id}, TTL={self.awaiting_final_ttl_ms}ms)")

    def _expire_snapshots(self, now_ms: int):
        """Commit expired snapshots to avoid data loss"""
        while self.awaiting_final and self.awaiting_final[0].expiry_ms <= now_ms:
            snap = self.awaiting_final.popleft()
            # High-recall choice: commit ALL tokens on expiry (after deduplication)
            tokens_to_commit = [t.text for t in snap.tokens]
            filtered_tokens = self._deduplicate_before_commit(tokens_to_commit)

            rescued = 0
            for token in filtered_tokens:
                self._stable.append(token)
                rescued += 1

            self._metrics["snapshot_expired_commits"] += rescued
            self.log.info(f"⏰ Expired snapshot auto-committed: {rescued} tokens (from seg {snap.segment_id})")

    # ---------- deduplication ----------
    def _deduplicate_before_commit(self, new_tokens: List[str]) -> List[str]:
        """
        Check if new_tokens are a duplicate or overlap of recent stable text.
        Uses sliding window matching to detect and remove RIVA's repetitive phrases.

        Args:
            new_tokens: Tokens to check for duplication

        Returns:
            Filtered tokens (may be empty if fully duplicate)
        """
        if not self.dedup_enabled or not new_tokens or not self._stable:
            return new_tokens

        # Get last N words from stable text for comparison
        # Use larger of window_size or 2x the new token length to catch long repetitions
        window_size = max(self.dedup_window_size, len(new_tokens) * 3)
        recent_stable = self._stable[-window_size:]

        # Convert to lowercase for case-insensitive comparison
        new_text_lower = [t.lower() for t in new_tokens]
        recent_text_lower = [t.lower() for t in recent_stable]

        # Check if new tokens are a substring of recent stable (full duplicate)
        if len(new_text_lower) <= len(recent_text_lower):
            for i in range(len(recent_text_lower) - len(new_text_lower) + 1):
                if recent_text_lower[i:i+len(new_text_lower)] == new_text_lower:
                    self.log.info(f"🚫 Dedup: Skipped full duplicate ({len(new_tokens)} tokens): '{detokenize(new_tokens)}'")
                    self._metrics["dedup_full_blocks"] += 1
                    self._metrics["dedup_tokens_removed"] += len(new_tokens)
                    return []

        # Check for partial overlap at the boundary (sliding window)
        # Find the longest suffix of recent_stable that matches a prefix of new_tokens
        best_overlap = 0
        for overlap_len in range(1, min(len(new_text_lower), len(recent_text_lower)) + 1):
            if recent_text_lower[-overlap_len:] == new_text_lower[:overlap_len]:
                best_overlap = overlap_len

        if best_overlap > 0:
            self.log.info(f"🔀 Dedup: Removed {best_overlap} overlapping tokens: '{detokenize(new_tokens[:best_overlap])}'")
            self._metrics["dedup_partial_overlaps"] += 1
            self._metrics["dedup_tokens_removed"] += best_overlap
            return new_tokens[best_overlap:]  # Skip the overlapping prefix

        return new_tokens

    # ---------- overlap / reconciliation ----------
    @staticmethod
    def _longest_suffix_prefix(context: List[str], final_tokens: List[str]) -> int:
        """Find longest suffix-prefix overlap between context and final"""
        max_m = min(len(context), len(final_tokens))
        for cand in range(max_m, -1, -1):
            if cand == 0:
                return 0
            # Case-insensitive comparison
            context_lower = [t.lower() for t in context[-cand:]]
            final_lower = [t.lower() for t in final_tokens[:cand]]
            if context_lower == final_lower:
                return cand
        return 0

    def _build_context_for_final(
        self,
        final_tokens: List[str],
        max_tail: int = 64
    ) -> Tuple[List[str], Optional[int], int, int, int]:
        """
        Build best-matching context for final reconciliation

        Returns:
          context_tokens,
          index_of_chosen_snapshot (or None),
          len_st_tail, len_snap, len_cur_pending
        """
        st_tail = self._stable[-max_tail:]
        pending_txt = [t.text for t in self.pending_tokens]

        best = ([], None, 0, 0, 0, 0)  # (ctx, snap_idx, len_st, len_snap, len_pend, overlap)

        # Try each snapshot (most recent first)
        candidates = list(enumerate(reversed(self.awaiting_final)))
        for rev_idx, snap in candidates:
            snap_tokens = [t.text for t in snap.tokens]
            ctx = st_tail + snap_tokens + pending_txt
            m = self._longest_suffix_prefix(ctx, final_tokens)
            if m > best[5]:
                snap_idx = len(self.awaiting_final) - 1 - rev_idx
                best = (ctx, snap_idx, len(st_tail), len(snap_tokens), len(pending_txt), m)

        # Also try without any snapshot
        ctx_nosnap = st_tail + pending_txt
        m0 = self._longest_suffix_prefix(ctx_nosnap, final_tokens)
        if m0 > best[5]:
            best = (ctx_nosnap, None, len(st_tail), 0, len(pending_txt), m0)

        return best[0], best[1], best[2], best[3], best[4]

    # ---------- core API ----------
    def add_partial(self, text: str, now_ms: Optional[int] = None) -> Dict:
        """
        Process a partial result from RIVA

        Args:
            text: Partial transcript text
            now_ms: Optional timestamp override for testing

        Returns:
            Display event dict
        """
        self._metrics["total_partials"] += 1
        now = self._now_ms() if now_ms is None else now_ms
        self._ensure_segment_started(now)
        self._expire_snapshots(now)

        cur_tokens = tokenize(text)
        self.log.debug(f"[PARTIAL #{self._metrics['total_partials']}] Input: '{text}' ({len(cur_tokens)} tokens)")

        # Record partial history for late-final rescue context
        self._record_partial_history(cur_tokens, now)

        # Align with existing pending by LCP
        prev_txt = [t.text for t in self.pending_tokens]
        l = lcp_len(prev_txt, cur_tokens)

        if l > 0:
            self.log.debug(f"  LCP: {l}/{len(prev_txt)} tokens unchanged")

        # Confirm LCP tokens
        for i in range(l):
            t = self.pending_tokens[i]
            t.confirmation_count += 1
            t.last_seen_time = self.time_fn()

        # Drop old pending beyond LCP
        dropped = len(self.pending_tokens) - l
        while len(self.pending_tokens) > l:
            self.pending_tokens.pop()
        if dropped > 0:
            self.log.debug(f"  Dropped {dropped} tokens (no longer in partial)")

        # Append new suffix as fresh tokens
        new_count = len(cur_tokens) - l
        if new_count > 0:
            self.log.debug(f"  Adding {new_count} new tokens: {cur_tokens[l:]}")
        for tok in cur_tokens[l:]:
            now_s = self.time_fn()
            self.pending_tokens.append(Token(tok, 1, now_s, now_s))

        # Promote leftmost ready (K/T)
        promoted = self._promote_leftmost_ready(now)
        if promoted > 0:
            self.log.info(f"  Promoted {promoted} tokens to stable")

        # Segment timeout => snapshot, roll, but DO NOT commit or clear evidence
        if self.segment_started_ms is not None and (now - self.segment_started_ms) >= self.max_segment_ms:
            self.log.info(f"  Max segment duration reached ({(now - self.segment_started_ms)/1000:.1f}s > {self.max_segment_ms/1000:.1f}s)")
            self.force_segment_break(now)

        return self.build_display_event(is_final=False)

    def add_final(self, text: str, now_ms: Optional[int] = None) -> Dict:
        """
        Process a final result from RIVA with cross-segment reconciliation

        Args:
            text: Final transcript text (per-utterance, not cumulative)
            now_ms: Optional timestamp override for testing

        Returns:
            Display event dict
        """
        self._metrics["total_finals"] += 1
        now = self._now_ms() if now_ms is None else now_ms
        self._ensure_segment_started(now)
        self._expire_snapshots(now)

        self.log.info(f"[FINAL #{self._metrics['total_finals']}] Input: '{text}'")

        final_tokens = tokenize(text)
        if not final_tokens:
            self.log.debug("  Empty final result, rolling segment")
            self.force_segment_break(now)
            return self.build_display_event(is_final=True)

        # Build context using best matching snapshot (if any)
        context, snap_idx, len_st_tail, len_snap, len_pend = self._build_context_for_final(final_tokens)
        m = self._longest_suffix_prefix(context, final_tokens)

        self.log.debug(f"  Context: {len_st_tail} stable tail + {len_snap} snapshot + {len_pend} pending = {len(context)} tokens")
        self.log.debug(f"  Final: {len(final_tokens)} tokens")
        self.log.debug(f"  Overlap: {m} tokens")

        # Compute rescue window for snapshot (left-of-overlap within snapshot slice)
        c_len = len(context)
        overlap_start = c_len - m

        rescued = 0
        if snap_idx is not None and len_snap > 0:
            # Snapshot token index range within context
            snap_start = len_st_tail
            snap_end = len_st_tail + len_snap - 1

            # Left-of-overlap area inside snapshot
            left_end = min(snap_end, overlap_start - 1)
            if left_end >= snap_start:
                left_count = (left_end - snap_start + 1)
                # Collect orphaned words for deduplication
                orphaned_words = []
                for i in range(left_count):
                    word = self.awaiting_final[snap_idx].tokens[i].text
                    orphaned_words.append(word)

                # Apply deduplication to orphaned words
                filtered_orphans = self._deduplicate_before_commit(orphaned_words)

                # Promote filtered snapshot tokens to stable (rescue orphans)
                for word in filtered_orphans:
                    self._stable.append(word)
                    rescued += 1

                # Remove from snapshot
                self.awaiting_final[snap_idx].tokens = self.awaiting_final[snap_idx].tokens[left_count:]

            # If overlap fully consumed snapshot, drop it
            if not self.awaiting_final[snap_idx].tokens:
                self.awaiting_final.remove(self.awaiting_final[snap_idx])

            if rescued:
                self._metrics["orphan_rescues"] += rescued
                self._metrics["late_final_hits"] += 1
                self._metrics["tokens_committed_by_final"] += rescued
                filtered_text = detokenize([t for t in filtered_orphans]) if rescued > 0 else ""
                self.log.info(f"  🎯 Late final matched snapshot from seg {self.segment_id}, rescued {rescued} ORPHANED tokens: '{filtered_text}'")

        # Append only the unmatched suffix of the final (after deduplication)
        to_append = final_tokens[m:]
        if to_append:
            filtered_append = self._deduplicate_before_commit(to_append)
            self._stable.extend(filtered_append)
            self._metrics["tokens_committed_by_final"] += len(filtered_append)
            self.log.info(f"  ✓ Committed {len(filtered_append)} NEW tokens from final: '{detokenize(filtered_append)}'")
        else:
            self.log.debug(f"  No new tokens (all {len(final_tokens)} already in context)")

        # Final closes utterance: clear current pending and roll segment
        pending_before = len(self.pending_tokens)
        self.pending_tokens.clear()
        if pending_before > 0:
            self.log.info(f"  Cleared {pending_before} pending tokens (utterance closed)")

        self.segment_id += 1
        self.segment_started_ms = now

        return self.build_display_event(is_final=True)

    def force_segment_break(self, now_ms: Optional[int] = None) -> None:
        """
        Force segment break on timeout (snapshots pending, doesn't drop evidence)

        Args:
            now_ms: Optional timestamp override for testing
        """
        now = self._now_ms() if now_ms is None else now_ms

        # Snapshot pending but DO NOT commit or clear history
        self._snapshot_pending(now)
        self.pending_tokens.clear()

        # Roll segment counters
        self.segment_id += 1
        self.segment_started_ms = now
        self._metrics["segment_rolls"] += 1
        self.log.info(f"🔄 Segment rolled (timeout). New segment={self.segment_id}")

    def reset(self):
        """Reset accumulator state for new session"""
        self._stable = []
        self.pending_tokens.clear()
        self.awaiting_final.clear()
        self.partial_history.clear()
        self.segment_id = 0
        self.segment_started_ms = None
        self.log.info("Accumulator reset")

    def get_final_transcript(self) -> str:
        """Get the final committed transcript"""
        return self.stable_text
