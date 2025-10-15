#!/usr/bin/env python3
"""
Server-Side Transcript Accumulator with Stability Windows
Handles RIVA's sliding-window partial results to prevent word loss
"""

import time
import logging
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime

logger = logging.getLogger(__name__)


@dataclass
class Token:
    """Represents a word/token with stability metadata"""
    text: str
    confirmation_count: int = 0
    first_seen_time: float = 0.0
    last_seen_time: float = 0.0

    def __post_init__(self):
        if self.first_seen_time == 0.0:
            self.first_seen_time = time.time()
        self.last_seen_time = time.time()


class TranscriptAccumulator:
    """
    Authoritative server-side accumulator for RIVA streaming transcripts.

    Strategy:
    - Partials are "replace-all hypotheses" (not deltas)
    - Only commit words that remain stable across K consecutive partials
    - Or commit immediately on RIVA finals
    - Force-flush tokens that have been pending for T milliseconds

    This prevents word loss due to RIVA's sliding window behavior.
    """

    def __init__(
        self,
        stability_threshold: int = 3,           # K: consecutive partials needed
        forced_flush_ms: int = 2000,            # T: max time before auto-commit
        max_segment_duration_s: float = 12.0,   # Force segment break
        enable_lcp_optimization: bool = True
    ):
        """
        Initialize accumulator

        Args:
            stability_threshold: Number of consecutive partials needed to commit a token
            forced_flush_ms: Milliseconds before force-committing a pending token
            max_segment_duration_s: Maximum segment duration before forced break
            enable_lcp_optimization: Use longest common prefix for efficiency
        """
        self.stability_threshold = stability_threshold
        self.forced_flush_ms = forced_flush_ms / 1000.0  # Convert to seconds
        self.max_segment_duration_s = max_segment_duration_s
        self.enable_lcp_optimization = enable_lcp_optimization

        # State
        self.stable_text = ""           # Committed words (source of truth)
        self.pending_tokens: List[Token] = []  # Candidates for commitment
        self.prev_partial = ""          # Previous partial for LCP comparison
        self.segment_start_time = time.time()
        self.segment_id = 0

        # Metrics
        self.total_partials = 0
        self.total_finals = 0
        self.tokens_committed_by_stability = 0
        self.tokens_committed_by_final = 0
        self.tokens_committed_by_flush = 0

        logger.info(
            f"TranscriptAccumulator initialized: K={stability_threshold}, "
            f"T={self.forced_flush_ms}s, max_segment={max_segment_duration_s}s"
        )

    def add_partial(self, text: str) -> Dict[str, any]:
        """
        Process a partial result from RIVA

        Args:
            text: Partial transcript text

        Returns:
            Display event dict with stable_text and partial_suffix
        """
        self.total_partials += 1
        current_time = time.time()

        # Tokenize (simple whitespace split for now)
        new_tokens = self._tokenize(text)

        logger.debug(f"[PARTIAL #{self.total_partials}] Input: '{text}' ({len(new_tokens)} tokens)")

        # Compute longest common prefix with previous partial
        if self.enable_lcp_optimization and self.prev_partial:
            prev_tokens = self._tokenize(self.prev_partial)
            lcp_length = self._compute_lcp_length(prev_tokens, new_tokens)
            logger.debug(f"  LCP: {lcp_length}/{len(prev_tokens)} tokens unchanged from previous partial")
        else:
            lcp_length = 0

        # Update pending tokens
        self._update_pending_tokens(new_tokens, lcp_length, current_time)

        # Force flush old tokens
        flushed = self._forced_flush_old_tokens(current_time)
        if flushed > 0:
            logger.info(f"  Forced flush: {flushed} tokens committed (age > {self.forced_flush_ms}s)")

        # Check for max segment duration
        segment_age = current_time - self.segment_start_time
        if segment_age > self.max_segment_duration_s:
            logger.info(f"  Max segment duration reached ({segment_age:.1f}s > {self.max_segment_duration_s}s)")
            self._force_segment_break(current_time)

        # Store for next comparison
        self.prev_partial = text

        # Build display event
        return self._build_display_event(text)

    def add_final(self, text: str) -> Dict[str, any]:
        """
        Process a final result from RIVA (per-utterance, not cumulative)

        Strategy (per ChatGPT & Gemini recommendation):
          1) Build context = tail(stable_tokens) + pending_tokens
          2) Find overlap m where context[-m:] == final[:m]
          3) COMMIT "orphaned" pending tokens (left-of-overlap) that final doesn't cover
          4) Append unmatched final suffix
          5) Clear pending

        This prevents word loss when RIVA finals are incomplete due to sliding window.

        Args:
            text: Final transcript text (for THIS utterance only)

        Returns:
            Display event dict with newly committed text
        """
        self.total_finals += 1
        current_time = time.time()

        logger.info(f"[FINAL #{self.total_finals}] Input: '{text}'")

        if not text or not text.strip():
            logger.debug("  Empty final result, skipping")
            return self._build_display_event("", is_final=True)

        final_tokens = self._tokenize(text)

        # Build alignment context: tail of stable + all pending
        MAX_TAIL = 64  # Bounded window for performance (covers typical utterances)
        stable_tokens = self._tokenize(self.stable_text)
        stable_tail = stable_tokens[-MAX_TAIL:] if len(stable_tokens) > MAX_TAIL else stable_tokens
        pending_texts = [token.text for token in self.pending_tokens]
        context = stable_tail + pending_texts

        logger.debug(f"  Context: {len(stable_tail)} stable tail + {len(pending_texts)} pending = {len(context)} tokens")
        logger.debug(f"  Final: {len(final_tokens)} tokens")

        # Find longest suffix-prefix overlap (m = overlap length)
        max_m = min(len(context), len(final_tokens))
        m = 0
        for cand in range(max_m, -1, -1):
            if cand == 0:
                m = 0
                break
            # Case-insensitive comparison (RIVA may change capitalization)
            context_suffix = [t.lower() for t in context[-cand:]]
            final_prefix = [t.lower() for t in final_tokens[:cand]]
            if context_suffix == final_prefix:
                m = cand
                logger.debug(f"  Found overlap: {m} tokens match between context tail and final prefix")
                break

        # Calculate how many context tokens the final "covers" (confirms/corrects)
        # The final confirms/corrects the last (len(final) - m) tokens of context
        covered_len = len(final_tokens) - m

        # Identify "orphaned" pending tokens (left-of-overlap)
        # These appeared in partials but are NOT covered by the final
        num_orphaned = max(0, len(pending_texts) - covered_len)
        orphaned_tokens = self.pending_tokens[:num_orphaned]

        logger.debug(f"  Final covers {covered_len} context tokens, {num_orphaned} pending tokens are orphaned")

        # COMMIT orphaned tokens (they're valid words RIVA dropped from final)
        if orphaned_tokens:
            orphaned_text = " ".join(token.text for token in orphaned_tokens)
            self.stable_text += orphaned_text + " "
            self.tokens_committed_by_final += len(orphaned_tokens)
            logger.info(f"  ✓ Committed {len(orphaned_tokens)} ORPHANED tokens (from partials, not in final): '{orphaned_text}'")

        # Append unmatched suffix of final (new tokens not in context)
        to_append = final_tokens[m:]
        if to_append:
            committed = " ".join(to_append)
            self.stable_text += committed + " "
            self.tokens_committed_by_final += len(to_append)
            logger.info(f"  ✓ Committed {len(to_append)} NEW tokens from final: '{committed}'")
        else:
            logger.debug(f"  No new tokens from final (all {len(final_tokens)} tokens already in context)")

        # Clear pending tokens (utterance closed, all handled)
        pending_before = len(self.pending_tokens)
        self.pending_tokens = []
        if pending_before > 0:
            logger.info(f"  Cleared {pending_before} pending tokens (utterance closed)")

        # Reset partial tracking for next utterance
        self.prev_partial = ""

        # DO NOT reset segment - keep building during continuous speech
        # Segment only resets on max duration timeout

        return self._build_display_event("", is_final=True)

    def _tokenize(self, text: str) -> List[str]:
        """Simple whitespace tokenization"""
        return [t.strip() for t in text.split() if t.strip()]

    def _compute_lcp_length(self, prev_tokens: List[str], new_tokens: List[str]) -> int:
        """
        Compute longest common prefix length between two token lists

        Returns:
            Number of tokens in common prefix
        """
        lcp = 0
        for i, (prev, new) in enumerate(zip(prev_tokens, new_tokens)):
            if prev.lower() == new.lower():
                lcp += 1
            else:
                break
        return lcp

    def _update_pending_tokens(
        self,
        new_tokens: List[str],
        lcp_length: int,
        current_time: float
    ):
        """
        Update pending token buffer with new partial

        Strategy:
        - Tokens in LCP region: increment confirmation count
        - New suffix tokens: add with count=1
        - Dropped tokens: removed (counts reset)
        - Tokens with count >= K: promote to stable
        """
        # Build new pending list
        updated_pending = []
        promoted_count = 0

        # Process tokens in LCP region (unchanged from previous partial)
        for i in range(min(lcp_length, len(self.pending_tokens))):
            token = self.pending_tokens[i]
            if i < len(new_tokens) and token.text.lower() == new_tokens[i].lower():
                # Token is stable, increment confirmation
                token.confirmation_count += 1
                token.last_seen_time = current_time

                # Check if ready to commit
                if token.confirmation_count >= self.stability_threshold:
                    self.stable_text += token.text + " "
                    self.tokens_committed_by_stability += 1
                    promoted_count += 1
                    logger.debug(f"  ✓ Promoted by stability (K={token.confirmation_count}): '{token.text}'")
                else:
                    updated_pending.append(token)
                    logger.debug(f"  Pending '{token.text}' count={token.confirmation_count}/{self.stability_threshold}")

        # Add new suffix tokens (beyond LCP)
        new_suffix_count = len(new_tokens) - lcp_length
        if new_suffix_count > 0:
            logger.debug(f"  Adding {new_suffix_count} new tokens to pending: {new_tokens[lcp_length:]}")

        for i in range(lcp_length, len(new_tokens)):
            updated_pending.append(Token(
                text=new_tokens[i],
                confirmation_count=1,
                first_seen_time=current_time,
                last_seen_time=current_time
            ))

        # Log summary
        dropped_count = len(self.pending_tokens) - lcp_length
        if dropped_count > 0:
            logger.warning(f"  ⚠ Dropped {dropped_count} tokens (no longer in partial)")

        self.pending_tokens = updated_pending

        if promoted_count > 0:
            logger.info(f"  Promoted {promoted_count} tokens to stable by K-confirmation")

    def _forced_flush_old_tokens(self, current_time: float) -> int:
        """
        Force-commit tokens that have been pending too long

        Returns:
            Number of tokens flushed
        """
        committed_count = 0
        remaining = []

        for token in self.pending_tokens:
            age = current_time - token.first_seen_time
            if age >= self.forced_flush_ms:
                # Force commit
                self.stable_text += token.text + " "
                self.tokens_committed_by_flush += 1
                committed_count += 1
                logger.info(f"  ✓ Forced flush (T={age:.2f}s): '{token.text}' count={token.confirmation_count}")
            else:
                remaining.append(token)

        self.pending_tokens = remaining
        return committed_count

    def _force_segment_break(self, current_time: float):
        """
        Force a segment break after max duration
        """
        logger.info(f"Max segment duration reached, forcing break (segment_id={self.segment_id})")

        # Commit all pending tokens
        for token in self.pending_tokens:
            self.stable_text += token.text + " "
            self.tokens_committed_by_flush += 1

        self.pending_tokens = []
        self.prev_partial = ""
        self.segment_start_time = current_time
        self.segment_id += 1

    def _build_display_event(self, current_partial: str, is_final: bool = False) -> Dict[str, any]:
        """
        Build display event for client

        Returns event with:
        - stable_text: Committed words (never regresses)
        - partial_suffix: Current unstable partial for UI feedback
        - is_final: Whether this was triggered by a final
        """
        # Extract pending text for display
        pending_text = " ".join(token.text for token in self.pending_tokens)

        event = {
            'type': 'display',
            'stable_text': self.stable_text.strip(),
            'partial_suffix': pending_text.strip(),
            'is_final': is_final,
            'segment_id': self.segment_id,
            'timestamp': datetime.utcnow().isoformat(),
            'metadata': {
                'pending_tokens': len(self.pending_tokens),
                'stable_word_count': len(self.stable_text.split()),
            }
        }

        return event

    def get_final_transcript(self) -> str:
        """
        Get the final committed transcript

        Returns:
            Complete stable text
        """
        return self.stable_text.strip()

    def get_metrics(self) -> Dict[str, any]:
        """
        Get accumulator metrics

        Returns:
            Dict with performance metrics
        """
        return {
            'total_partials': self.total_partials,
            'total_finals': self.total_finals,
            'tokens_committed_by_stability': self.tokens_committed_by_stability,
            'tokens_committed_by_final': self.tokens_committed_by_final,
            'tokens_committed_by_flush': self.tokens_committed_by_flush,
            'current_pending_tokens': len(self.pending_tokens),
            'current_stable_word_count': len(self.stable_text.split()),
            'current_segment_id': self.segment_id,
            'segment_duration_s': time.time() - self.segment_start_time
        }

    def reset(self):
        """Reset accumulator state for new session"""
        self.stable_text = ""
        self.pending_tokens = []
        self.prev_partial = ""
        self.segment_start_time = time.time()
        self.segment_id = 0
        logger.info("Accumulator reset")


# Example usage
if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)

    # Simulate RIVA streaming behavior
    accumulator = TranscriptAccumulator(
        stability_threshold=2,
        forced_flush_ms=1500
    )

    # Simulate counting scenario
    print("=== Simulating counting test ===\n")

    # Partials with sliding window behavior
    partials = [
        "one",
        "one two",
        "two three",
        "two three four",
        "three four",
        "four five",
        "five six",
        "six seven eight",
        "seven eight",
        "eight nine"
    ]

    for i, partial in enumerate(partials):
        result = accumulator.add_partial(partial)
        print(f"Partial {i+1}: '{partial}'")
        print(f"  → Stable: '{result['stable_text']}'")
        print(f"  → Pending: '{result['partial_suffix']}'")
        print(f"  → Display: '{result['stable_text']} {result['partial_suffix']}'")
        print()
        time.sleep(0.3)  # Simulate timing

    # Simulate final
    print("Final: 'eight nine ten'")
    result = accumulator.add_final("eight nine ten")
    print(f"  → Final stable: '{result['stable_text']}'")
    print()

    print("=== Metrics ===")
    for key, value in accumulator.get_metrics().items():
        print(f"  {key}: {value}")
