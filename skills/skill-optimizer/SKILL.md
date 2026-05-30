---
name: skill-optimizer
version: 0.1.0
description: Self-evolving skill optimization via SkillOpt-paper-grounded text-space optimizer.
triggers:
  - "optimize this skill"
  - "tune the skill against the benchmark"
  - "make the skill better"
  - "run skillopt"
  - "skillopt for"
mutating: true
brain_first: exempt
---

# Skill Optimizer

Self-evolving skill optimization. Treats SKILL.md as the trainable parameters
of a frozen agent. Validation-gated, budget-capped, atomic-versioned.

Based on SkillOpt (arXiv 2605.23904, Microsoft Research, May 2026).

## When to invoke this skill

The user wants to:
- Improve an existing skill's execution quality against a benchmark
- Bootstrap a benchmark file for a new skill
- Re-tune a skill after switching target models

## Iron Law

- **Validation gating is MANDATORY.** Every candidate must clear median-of-3
  + epsilon=0.05 margin against the sel-set before SKILL.md gets rewritten.
- **Frontmatter mutation is FORBIDDEN.** The optimizer only edits the body.
  Routing surface (`triggers:`, `brain_first:`) stays invariant.
- **Bundled skills require explicit opt-in.** Skills shipping with gbrain
  cannot be auto-mutated; user passes `--allow-mutate-bundled` or
  `--no-mutate` (default for the dream-cycle phase) writes proposed.md
  for review.
- **Bootstrap output requires human review.** `--bootstrap-from-routing`
  writes a sentinel; user must hand-review + delete the sentinel +
  re-run with `--bootstrap-reviewed` before optimization can use it.

## The pipeline

```
gbrain skillopt <skill-name> [flags]
  │
  ├── Pre-flight gates
  │     ├── working tree clean (or --force)
  │     ├── benchmark valid + D_sel >= 5 (D17)
  │     ├── cost preflight (D3) — refuses over --max-cost-usd
  │     └── per-skill DB lock (D14)
  │
  ├── Baseline eval on D_sel (sets best_sel_score)
  │
  ├── for epoch in 1..N:
  │     for step in 1..steps_per_epoch:
  │       ├── forward pass: rollouts on D_train batch
  │       ├── backward pass: reflect × 2 (failures + successes per D7)
  │       ├── rank + clip via LR cosine schedule
  │       ├── apply edits (body-only per D5, tagged result per D9)
  │       ├── validation gate: median-of-3 + epsilon=0.05 (D12)
  │       └── if accept: commit via D8 history-intent-first
  │     │
  │     └── slow update (D6) if no improvement this epoch
  │
  └── Final test eval on D_test → run receipt
```

## Authoring the benchmark yourself (the common case)

**The user will NOT hand-write a benchmark. You write it for them.** When the
user says "make skill X better" and `skills/X/skillopt-benchmark.jsonl` doesn't
exist, do NOT stop and ask them to author one, and do NOT reach for
`--bootstrap-from-routing` unless a `routing-eval.jsonl` already exists (it
generates tasks from ROUTING fixtures, which test dispatch, not output quality).
Instead, author a quality benchmark from the skill itself:

1. **Read `skills/X/SKILL.md`.** Identify what the skill is supposed to produce
   and what "good" looks like — the sections, the must-haves, the length ceiling,
   whether citations/tool-calls are expected.
2. **Generate ~15 realistic tasks** covering the cases the skill actually handles
   (the boring middle, not just edge cases). Each task is the prompt a user would
   actually send.
3. **Attach a rule judge to each task** — deterministic, free, no LLM call. Encode
   what good output requires:
   - `{"op":"contains","arg":"<must-have substring>"}`
   - `{"op":"max_chars","arg":<ceiling>}` — punishes padding
   - `{"op":"min_citations","arg":<n>}` — when sources are expected
   - `{"op":"section_present","arg":"<heading>"}`, `{"op":"regex","arg":"..."}`,
     `{"op":"tool_called","arg":"<tool>"}`, `{"op":"tool_not_called","arg":"<tool>"}`
4. **Write the JSONL** (one task per line) to `skills/X/skillopt-benchmark.jsonl`.
5. **Run with `--split 1:1:1`** so 15 tasks split a clean 5 train / 5 sel / 5 test.
   The default `4:1:5` split needs ~50 tasks (sel = N/10, floor 5) and will
   refuse a smaller benchmark with `D_sel has N task(s) (need >=5)`.
6. **Dry-run first** (`--dry-run`) to show the user the cost estimate before
   spending. Then run for real, read the outcome, and report back what changed
   and the score delta.

Benchmark line shape:
```
{"task_id":"x-001","task":"<user prompt>","judge":{"kind":"rule","checks":[{"op":"max_chars","arg":1800},{"op":"contains","arg":"agenda"}]}}
```

The human walkthrough of this same flow (with a complete 15-task starter) lives
at `docs/tutorials/improving-skills-with-skillopt.md`. The benchmark IS the
definition of quality — author it carefully; a thin benchmark optimizes for a
thin definition.

## Decision tree

| Situation | Action |
|---|---|
| Skill has no benchmark | **Author one** (see section above), then `gbrain skillopt foo --split 1:1:1` |
| Skill has a `routing-eval.jsonl` and you want a head start | `gbrain skillopt foo --bootstrap-from-routing` → review the generated tasks → `--bootstrap-reviewed` (routing tasks test dispatch; tighten them into quality tasks before trusting) |
| Iterating on an existing skill | `gbrain skillopt foo --benchmark skills/foo/skillopt-benchmark.jsonl` |
| Costly run, want preview | Add `--dry-run` |
| Bundled skill (skills/ in gbrain repo) | Default writes proposed.md; add `--allow-mutate-bundled` to commit |
| Want to review changes before applying | Add `--no-mutate` |
| Mid-run crash | `gbrain skillopt foo --resume <run-id>` |

## Output Format

When invoked, this skill produces:

- Updated `skills/<name>/SKILL.md` (when mutation is allowed)
- `skills/<name>/skillopt/best.md` — pointer copy of current best
- `skills/<name>/skillopt/versions/vNNNN_eN_sN.md` — per-step snapshots
- `skills/<name>/skillopt/history.json` — append-only run record
- `skills/<name>/skillopt/rejected.json` — bounded LRU of rejected edits
- `~/.gbrain/audit/skillopt-YYYY-Www.jsonl` — ISO-week-rotated audit trail

## Anti-Patterns

- **Don't bypass the validation gate.** The median-of-3 + epsilon=0.05 is
  load-bearing; without it, the optimizer accepts noise as improvement.
- **Don't optimize bundled skills without `--allow-mutate-bundled`.** They
  ship with gbrain and are load-bearing for downstream agents.
- **Don't use `--bootstrap-from-routing` output without review.** The
  optimizer model invents success criteria; a human must sanity-check
  before SkillOpt optimizes against them.

## Contract

`runSkillOpt(opts)` returns:
```
{
  outcome: 'accepted' | 'no_improvement' | 'aborted' | 'errored',
  receipt: { run_id, skill_sha8, benchmark_sha8, models, scores, cost },
  finalText: string,
  mutatedSkillFile: boolean,
  proposedPath?: string
}
```

## Related skills

- `skillify` — scaffolds a new skill (use BEFORE skillopt)
- `skillpack-check` — audits skill conformance (item 13 surfaces skillopt status)
- `conventions/quality.md` — output quality standards skillopt enforces via judges
