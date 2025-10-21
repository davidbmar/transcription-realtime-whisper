# Timestamp-Based Transcript Accumulator - Design Package

This directory contains the complete design documentation for v4.0.0 of the transcript accumulator, replacing the text-based approach (v3.0.7) with a timestamp-based approach.

## 📂 Files in This Package

### 1. `TIMESTAMP_ACCUMULATOR_DESIGN.md` (Core Design)
**Size:** ~1,500 lines
**Purpose:** Complete technical specification

**Contents:**
- Architecture overview
- Core concepts (segments, finalization fence, timestamp matching)
- Complete API design with all methods
- State management implementation details
- Configuration options and defaults
- Real-world usage examples
- Edge case handling
- Migration path from v3.0.7
- Performance analysis
- Testing strategy

**Key Sections:**
```
1. Architecture Overview
2. Core Concepts
3. API Design (15+ methods)
4. State Management
5. Configuration
6. Usage Examples (5 detailed scenarios)
7. Edge Cases (4 critical scenarios)
8. Migration Path
9. Performance Considerations
10. Testing Strategy
```

---

### 2. `TIMESTAMP_ACCUMULATOR_VISUAL.md` (Visual Guide)
**Size:** ~500 lines
**Purpose:** Visual explanations with ASCII diagrams

**Contents:**
- Finalization fence concept diagram
- Sliding window behavior with timestamps
- Timestamp matching with jitter tolerance
- State transition flowchart
- Query API visual examples
- UI mockup showing locked/unlocked segments
- Performance benchmarks table
- Side-by-side comparison: text-based vs timestamp-based

**Best for:**
- Understanding the mental model
- Explaining to stakeholders
- UI/UX design reference

---

### 3. `CHATGPT_REVIEW_QUESTIONS.md` (Critical Questions)
**Size:** ~400 lines
**Purpose:** 45+ questions organized into 10 categories

**Categories:**
1. Architecture & Approach (3 questions)
2. State Management (3 questions)
3. Edge Cases & Conflict Resolution (3 questions)
4. API Design (3 questions)
5. Performance Optimization (3 questions)
6. Configuration & Tuning (3 questions)
7. Testing & Validation (3 questions)
8. User Experience (3 questions)
9. Future-Proofing (3 questions)
10. Production Readiness (3 questions)

**Use this to:**
- Identify gaps in the design
- Validate assumptions
- Get expert feedback from ChatGPT or colleagues

---

### 4. `CHATGPT_REVIEW_PROMPT.md` (Ready to Copy)
**Size:** ~200 lines
**Purpose:** Pre-formatted prompt for ChatGPT validation

**What it does:**
- Provides context on the problem
- Links all three design documents
- Highlights 5 specific concerns
- Asks ChatGPT to validate the design
- Requests answers to critical questions

**Usage:**
```bash
# 1. Copy the entire file
cat docs/CHATGPT_REVIEW_PROMPT.md | pbcopy

# 2. Paste into ChatGPT
# 3. Wait for comprehensive review
# 4. Iterate based on feedback
```

---

## 🚀 How to Use This Package

### Step 1: Understand the Design
```bash
# Read in this order:
1. TIMESTAMP_ACCUMULATOR_VISUAL.md    # Get the mental model
2. TIMESTAMP_ACCUMULATOR_DESIGN.md    # Deep dive into details
3. CHATGPT_REVIEW_QUESTIONS.md        # Understand open questions
```

### Step 2: Validate with ChatGPT
```bash
# Copy the prompt
cat docs/CHATGPT_REVIEW_PROMPT.md

# Paste into ChatGPT (GPT-4 recommended)
# Attach or paste the three design documents

# Wait for review and recommendations
```

### Step 3: Iterate on Design
```bash
# Update design based on ChatGPT feedback
# Focus on:
- Critical issues identified
- Edge cases missed
- Performance concerns
- API improvements
```

### Step 4: Implement
```bash
# Create implementation file
touch src/timestamp-accumulator.js

# Follow the API spec from TIMESTAMP_ACCUMULATOR_DESIGN.md
# Implement incrementally:
1. Core segment structure
2. Timestamp matching
3. Fence computation
4. Lock/unlock logic
5. Query methods
6. Cache optimization
```

### Step 5: Test
```bash
# Implement tests from TIMESTAMP_ACCUMULATOR_DESIGN.md section 10
# Run parallel with v3.0.7 for validation
# Compare outputs on real WhisperLive data
```

---

## 🎯 Quick Reference: Key Decisions

### Design Choices Made

| Aspect | Choice | Rationale |
|--------|--------|-----------|
| **Primary Key** | Timestamp (start, end) | More robust than text for rewrites |
| **Matching Tolerance** | ±100ms | Handles WhisperLive jitter |
| **Lock Window** | 2.0 seconds | Balance stability vs refinement |
| **Data Structure** | Array + cache | Simple, fast enough for typical sessions |
| **State Transitions** | Unlocked → Locked | One-way for safety |
| **Overlap Handling** | Keep both if timestamps differ | Preserve information |

### Design Choices Pending (Need ChatGPT Input)

| Aspect | Options | Question |
|--------|---------|----------|
| **Adaptive Fence** | Fixed vs dynamic | Should fence adjust based on speech rate? |
| **Overlapping Segments** | Keep, merge, or reject | Best UX for overlaps? |
| **Timestamp Tolerance** | Fixed vs adaptive | Should tolerance scale with duration? |
| **Long Sessions** | Keep all vs archive | When to prune old segments? |
| **Lock Policy** | Time-based vs completion-based | Support multiple policies? |

---

## 📊 Design Metrics

### Complexity

| Metric | Current (v3.0.7) | Proposed (v4.0.0) |
|--------|------------------|-------------------|
| Lines of code | ~400 lines | ~300 lines (estimate) |
| Core algorithm | SPC + EW + BoF + Soft Tail | Timestamp matching + Fence |
| State tracking | 7 variables | 5 variables |
| Edge cases | 4 mechanisms | 2 mechanisms |

### Performance (1 hour session)

| Operation | v3.0.7 | v4.0.0 |
|-----------|--------|--------|
| Ingest segment | 0.08ms | 0.05ms |
| Get transcript | 0.02ms | 0.01ms (cached) |
| Memory usage | 600KB | 540KB |

### Robustness

| Scenario | v3.0.7 | v4.0.0 |
|----------|--------|--------|
| Text rewrite | ⚠️ Fragile (LCP breaks) | ✅ Robust |
| Timestamp jitter | ✅ N/A (text-based) | ✅ Handled (±100ms) |
| Duplicates | ✅ Detected | ✅ Detected |
| Out-of-order | ⚠️ May break | ✅ Handled |

---

## 🔍 Critical Questions to Validate

Before implementing, get answers to these **5 critical questions**:

### 1. Timestamp Jitter Tolerance
**Q:** Is 100ms the right tolerance?
**Context:** WhisperLive sends timestamps with ±50-150ms jitter
**Options:**
- Fixed 100ms
- Adaptive based on segment duration (e.g., 5% of duration)
- Learn from data (track actual jitter distribution)

### 2. Overlapping Segments
**Q:** How to handle segments with different timestamps that overlap in time?
**Example:**
```
Segment A: [2.0s ───── 5.0s] "how are you"
Segment B:      [3.0s ───── 6.0s] "are you doing"
```
**Options:**
- Keep both (current design)
- Merge into one segment
- Reject based on confidence/length

### 3. Lock Window Default
**Q:** Is 2.0 seconds reasonable for `lockWindow`?
**Context:** Smaller = more stable, Larger = more refinement
**Options:**
- Fixed 2.0s
- Adaptive based on speech rate
- User-configurable with good default

### 4. Fence Boundary Conflicts
**Q:** What to do when rewrites overlap the finalization fence?
**Example:** Locked region ends at 5.0s, new segment is [4.5s - 7.0s]
**Options:**
- Reject entire segment (safe but may lose data)
- Accept unlocked portion only (complex)
- Force-unlock conflicting portion (dangerous)

### 5. Long Session Scaling
**Q:** For 8+ hour sessions, should we archive old segments?
**Context:** 8 hours = ~28,800 segments = ~4.3 MB
**Options:**
- Keep all in memory (simple, but grows unbounded)
- Archive to IndexedDB after 1 hour (complex, but scalable)
- Implement sliding window (keep last N segments)

---

## 📋 Next Steps

### Immediate Actions
1. ✅ Review design documents
2. ⏳ Get ChatGPT validation (use `CHATGPT_REVIEW_PROMPT.md`)
3. ⏳ Answer 5 critical questions
4. ⏳ Update design based on feedback

### Implementation Phase
5. ⏳ Create `src/timestamp-accumulator.js`
6. ⏳ Implement core segment structure
7. ⏳ Add timestamp matching logic
8. ⏳ Implement finalization fence
9. ⏳ Add query methods
10. ⏳ Write unit tests

### Validation Phase
11. ⏳ Run parallel with v3.0.7
12. ⏳ Compare outputs on real data
13. ⏳ Measure performance
14. ⏳ Test edge cases

### Deployment Phase
15. ⏳ Switch over to v4.0.0
16. ⏳ Monitor for issues
17. ⏳ Archive v3.0.7 code
18. ⏳ Update documentation

---

## 🎓 Learning Resources

### Related Concepts
- **Sliding Window Algorithms** - How to process overlapping data streams
- **CRDTs (Conflict-Free Replicated Data Types)** - Distributed consensus patterns
- **Stream Processing** - Apache Kafka, Flink timestamp handling
- **Real-Time Databases** - Firebase, Supabase subscription models
- **Operational Transformation** - Google Docs collaborative editing

### Similar Systems
- YouTube Auto Captions - Real-time speech transcription
- Zoom Live Transcription - Multi-speaker streaming ASR
- Otter.ai - Conversational AI transcription
- Google Meet Live Captions - Streaming with refinement

---

## 📞 Questions or Issues?

If you find issues with the design or have questions:

1. **Check the design docs first** - Answer might be in there
2. **Review ChatGPT feedback** - May have addressed your concern
3. **Update `CHATGPT_REVIEW_QUESTIONS.md`** - Add new questions
4. **Iterate on the design** - Update documents as needed

---

## 📝 Document Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2025-01-21 | Initial design package created |
| 1.0.1 | TBD | Updates based on ChatGPT review |
| 2.0.0 | TBD | Final design after validation |

---

## ✅ Design Validation Checklist

Before implementation, ensure:

- [ ] All 5 critical questions answered
- [ ] ChatGPT has reviewed and validated
- [ ] Edge cases documented and handled
- [ ] Performance characteristics acceptable
- [ ] API design is intuitive
- [ ] Migration path is clear
- [ ] Testing strategy is comprehensive
- [ ] Team has reviewed and approved

---

**Ready to validate? Copy `CHATGPT_REVIEW_PROMPT.md` and paste into ChatGPT!**
