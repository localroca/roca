# Issue Triage

This guide keeps public issue intake consistent and readable.

## Labels

Use GitHub default labels where they fit:

- `bug`
- `documentation`
- `duplicate`
- `enhancement`
- `good first issue`
- `help wanted`
- `invalid`
- `question`
- `wontfix`

Use one or more area labels:

- `area:app`
- `area:assistant`
- `area:community`
- `area:companion`
- `area:privacy`
- `area:providers`
- `area:release`
- `area:workflow`

Use one priority label when priority is clear:

- `priority:p0`: required before the next public milestone.
- `priority:p1`: important planned work.
- `priority:p2`: useful follow-up work.
- `priority:p3`: later or lower-priority work.

Use need labels when the issue cannot move forward yet:

- `needs:triage`
- `needs:repro`
- `needs:decision`
- `needs:design`
- `needs:tests`

Use `status:blocked` when work is accepted but blocked by another dependency.

Use `roadmap` only for issues tracked in the public roadmap project.

## Triage Flow

1. Confirm the issue is understandable and actionable.
2. Ask for missing environment, reproduction, or scope details when needed.
3. Apply the relevant default, area, priority, need, and status labels.
4. Add `roadmap` only when the issue belongs on the public roadmap.
5. Remove credentials, private prompts, transcripts, or other sensitive data
   from public issue discussion.

## Roadmap Rules

Public roadmap items should describe user value, public architecture, privacy
behavior, release readiness, or contributor-facing work.
