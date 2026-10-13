# Architecture Decision Records

An ADR captures one significant architectural decision: the context that forced
it, the decision itself, and the consequences we accept. ADRs are short (aim for
under 40 lines), immutable once accepted, and numbered sequentially.

## When to write one
- Before reversing or materially bending a decision in `PLAN.md` §5/§6 or an
  existing ADR.
- When choosing between two viable approaches that will be hard to change later
  (persistence layer, IPC design, distribution model, test strategy).
- When a reviewer asks "why did we do it this way?" and the answer is not in code.

Small, reversible choices (naming, file layout, a library pick inside one
package) do not need an ADR; a commit message is enough.

## Process
1. Copy the template below into `docs/adr/NNNN-short-kebab-title.md` using the
   next free number.
2. Status starts as **Proposed**. Open a PR; discussion happens on the PR.
3. On merge the status becomes **Accepted**. Never edit the Decision of an
   accepted ADR. To change course, write a new ADR and mark the old one
   **Superseded by NNNN** in its header.
4. Reference the ADR from code comments and commit messages where it applies
   (`// see ADR 0003`).

## Template
```markdown
# NNNN. Title

Status: Proposed | Accepted | Superseded by NNNN
Date: YYYY-MM-DD

## Context
What forces are at play: platform facts, product requirements, constraints.

## Decision
What we are doing, stated in the active voice.

## Consequences
What becomes easier, what becomes harder, what we must now do or never do.
```

## Index
| # | Title |
|---|---|
| [0001](0001-direct-distribution-no-sandbox.md) | Direct distribution, no App Sandbox |
| [0002](0002-privileged-helper-xpc-closed-operation-set.md) | Privileged helper exposes a closed operation set over XPC |
| [0003](0003-trash-first-deletion-with-undo-manifest.md) | Trash-first deletion with an undo manifest |
| [0004](0004-foundation-only-core-for-linux-ci.md) | Foundation-only core packages verified on Linux CI |
