# Model Evaluations

Roca uses a small eval harness to compare local Ollama models for assistant
roles. The harness is intended for maintainers or AI coding agents to run,
inspect, and summarize. It is not a fully automatic judge.

## What Is Tracked

- Test cases: `evals/suites/assistant_quality_v1.json`
- Compact app-consumed assessments:
  `Packages/RocaProviders/Sources/RocaProviders/Resources/ModelAssessments/*.json`

## What Is Ignored

- Full raw runs: `evals/results/<run-id>/`
- Generated judge packets and response logs from each run.

## Run The Harness

Make sure Ollama is running and the target models are installed.

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/roca-clang-cache swift run RocaEval run --models qwen3:4b-instruct,mistral:7b
```

Useful focused smoke run:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/roca-clang-cache swift run RocaEval run --models qwen3:4b-instruct --scenarios casual_check_in,open_safari --repeats 1
```

Use `swift run RocaEval help` for the full option list.

## Review Workflow

1. Run the harness for the model set being compared.
2. Review `evals/results/<run-id>/judge_packet.md`.
3. Spot-check `responses.jsonl` when a model's behavior looks surprising.
4. Inspect the compact assessment diff.
5. Commit assessment updates only when the quality labels and speed hints match
   the reviewed evidence.

Each request has an eval-only timeout of 300 seconds. Normal app chat timeouts
are separate.

## Assessment Behavior

Each compact assessment file is one model. Quality is stored by role. Speed is
stored by hardware profile, so a run on a different Mac adds or updates that
profile without replacing existing speed results.

The app uses these compact files for quality icons and device-relative speed
hints. Full raw runs stay local unless we intentionally publish a result.

## Agent Scenarios

Agent-routing scenarios are dry-run only. They verify that the model emits the
right provider, project phrase, task prompt, and mode, but the harness never
starts Codex, Claude, Cursor, or any other external agent.
