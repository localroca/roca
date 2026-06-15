# Assistant Interaction Evals

Roca uses interaction evals to exercise the assistant as a product flow: user
turns, routing, mocked agent handoffs, chat transcript shape, speech output,
approval cards, diagnostics, and follow-up context.

This is separate from model evaluations. `assistant_quality_v1` compares local
Ollama models for routing/chat quality and speed labels. Interaction evals test
whether Roca behaves correctly around those model calls.

## Run

Scripted mode is the default and never calls Codex, Claude, Cursor, Ollama, or
real desktop actions.

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/roca-clang-cache swift run RocaEval interactions --suite evals/suites/assistant_interactions_v1.json
```

Model-in-loop mode uses Ollama for Roca's router and formatter prompts while
still mocking external agents and desktop actions.

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/roca-clang-cache swift run RocaEval interactions --mode model-in-loop --model qwen3:4b-instruct
```

Use `--strict` when a CI-style nonzero exit is useful. Without `--strict`, the
command writes failures to the report and exits successfully unless the runner
itself fails.

## Outputs

Raw outputs are ignored under `evals/results/<run-id>/`.

- `interaction_run.json`: run summary and counts.
- `interaction_transcripts.jsonl`: one record per turn with messages, speech,
  agent requests, diagnostics, project writes, and brain requests.
- `interaction_report.md`: human-readable pass/fail report.

Tracked inputs live in `evals/suites/assistant_interactions_v1.json`.

## Test Layers

- Deterministic Swift tests: fast unit coverage for orchestrator behavior,
  fixture decoding, runner logic, and report writing.
- Scripted interaction evals: product-flow checks with scripted router and
  formatter output.
- Model-in-loop interaction evals: prompt and local-model checks with mocked
  agents.
- Transcript replay: redacted dogfood failures converted into fixtures.
- Manual dogfood: final taste check for timing, voice feel, and trust.

This mirrors the useful parts of mature agent-eval systems: curated offline
datasets, trace-style artifacts, deterministic checks, and optional human
review. Useful references include LangSmith eval concepts, OpenAI Agents SDK
tracing/handoffs/sessions, OpenClaw QA scenarios, Promptfoo, DeepEval, and
AutoGen termination patterns.

## Fixture Shape

Each scenario declares local fixtures and observable expectations:

- `projects`: static project catalog entries.
- `agent`: mocked provider behavior: `normal`, `noisy`, or `hanging`.
- `turns`: user text, input/output mode, scripted brain output, optional
  approval prompt, optional cancellation.
- `expectations`: required chat messages, forbidden text, spoken text, agent
  request count/request shape, diagnostics, memory context, and project writes.

Use `expectedFailureReason` only for a known open issue. Remove it when the
behavior is fixed.

## What Must Be Mocked

Interaction evals must not call real external agents or mutate the desktop.

- Codex, Claude, Cursor, and future coding agents.
- App opening/quitting.
- Focused text insertion.
- Selected-text reading unless a scenario explicitly uses a fake reader.
- Project discovery except through fixture candidates/errors.
- Speech playback; only requested speech text is recorded.

## Adding A Scenario

1. Add the smallest fixture that reproduces the behavior.
2. Assert observable product output, not private implementation details.
3. Include negative checks for common regressions, such as raw tool chatter in
   chat or full Markdown details in TTS.
4. Add a deterministic Swift test only when the behavior is easier to express
   in code than JSON.
5. Run scripted mode. If the scenario targets prompt behavior, also run
   model-in-loop mode for the candidate model.

## Optimization Levers

Interaction quality is not just prompts. These are the main knobs:

- Router prompt and directive schema.
- Formatter prompt and `bubbleText` / `detailsMarkdown` rules.
- Parser tolerance and friendly recovery.
- Context assembly from active app, project identity, prior messages, and
  agent results.
- Conversation memory shape and trimming.
- Deterministic orchestration rules before and after model calls.
- UI affordances: action bubbles, approval cards, details blocks, status text.
- Speech policy: what to speak, what to keep visual, and TTS sanitization.
- Model choice per role.
- Latency, timeout, cancellation, and retry behavior.
- Diagnostics quality for debugging without exposing raw private content.
