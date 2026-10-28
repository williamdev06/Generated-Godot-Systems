# CLAUDE.md

Repo-root instruction file. Sections 1–7 govern every response; 8–9 govern
persistence across sessions. Appendix is the seed for `ARCHITECTURE.md`.

---

## OPERATING CONTRACT

You are working on a long-lived codebase across many short, disconnected sessions.
You have no memory between sessions. Optimize every response for the next session's
cost, not this one's comfort. Optimize the tasks you take to utilize and save as much token limits as you can without sacrificing quality.

---

### 1. Output shape

- No preamble, no restatement of my request, no summary of what you did unless the
  change spans more than one file.
- No praise, no "good catch", no "you're absolutely right". Correct or don't.
- Never reprint a file to change part of it. Emit the smallest unambiguous unit: a
  function, a block, or a `find`/`replace` pair with 2 lines of anchor context.
- Prose only where it carries information a comment cannot. Rationale for a
  non-obvious decision: yes. Explanation of what the code plainly does: no.
- If the answer is code, lead with the code.

---

### 2. Minimal implementation

Write the least code that satisfies the literal request. Everything below is
forbidden unless I asked for it by name.

**Do not add:**
- Features, mechanics, modes, or behaviours not requested.
- Configuration: exported variables, parameters, tunables, settings. Hardcode the
  value I gave you.
- Abstraction with one implementation. No interface, base class, factory, manager,
  registry, or event bus until a second concrete case exists.
- Error handling for conditions I did not name. Handle the failures I described;
  let the rest crash loudly.
- Defensive checks for states the caller already guarantees.
- Logging, telemetry, debug output, profiling scaffolding.
- Tests, unless requested.
- Fallback paths for states that cannot occur.
- Caching, pooling, batching, or any optimization not motivated by a measurement I
  gave you.
- Creating code that is hard to read and hard to maintain. Variable names should be descriptive rather than short and non descriptive: Example variable of cell should be named cell not c, group should be group not g.
- Docstrings beyond the header contract in §5.

**Do:**
- Prefer editing existing code over adding new code.
- Prefer a new function in an existing file over a new file.
- Inline a literal; promote it to a constant only on second use.
- Creating code needs to be easily readable and good for human understanding and further development.
- Follow the patterns already in the file, even if you would do it differently.
  Say so in one line if it matters; do not unilaterally diverge.

**Checks before you answer:**
- If I asked for X and your code also does Y, delete Y.
- If a task that sounded small produced more than ~50 lines, stop and confirm
  before continuing.
- Anything you wanted to add but didn't goes in a single `DEFERRED:` line at the
  end. One line total, not a section.

Ambiguity is not licence to build both branches. Ask.

---

### 3. Scope discipline

- Change exactly what was asked. Adjacent improvements go in the `DEFERRED:` line,
  never into the diff.
- One session touches one module. If the task genuinely requires a second module,
  stop before writing anything: `SCOPE: needs <A> and <B>. Split, or proceed?`
- Never refactor, rename, reformat, reorder, or reindent anything you were not
  asked to touch.

---

### 4. Never guess at the codebase

- If you have not been shown a file, signature, or API in this session, you do not
  know it. Do not infer it from the name.
- When you need something, request it by exact path and symbol, batched in one
  message, before writing code. Not one file at a time.
- Never invent engine or library API. If unsure a method exists, write
  `UNVERIFIED: <symbol>` and continue; do not substitute a plausible name.
- Distinguish clearly between what I told you, what you read, and what you assumed.

---

### 5. Comments

Two kinds only.

**Required** — header block on every file you create or substantially edit:

```
# OWNS:       <the one responsibility of this file>
# DEPENDS:    <external systems/singletons this reads or calls>
# INVARIANTS: <what must stay true; what breaks if violated>
# GOTCHAS:    <non-obvious constraints, ordering, engine quirks>
```

Reference `ARCHITECTURE.md` IDs where they exist (`see INV-4`) instead of restating.

**Allowed inline** — non-obvious *why*, workarounds for upstream bugs with issue
link, ordering requirements, units and coordinate spaces.

**Forbidden** — restating the code, section banners, changelogs, ownerless TODOs,
commented-out code.

---

### 6. Interfaces over internals

- Module boundaries are contracts. If a change alters a public signature, flag it:
  `BREAKS: <signature> — callers: <list, or "unknown, please grep">`.
- Prefer passing data over reaching into another system's state.
- New cross-module coupling requires one line of justification before you write it.

---

### 7. Uncertainty

Say "I don't know" or "this needs verification" rather than producing confident
plausible output. A wrong answer costs a debug session; an admission costs a line.
When there are several options, rank them and recommend one. Never present a menu
without a recommendation.

---

### 8. ARCHITECTURE.md maintenance

`ARCHITECTURE.md` at repo root is the project map. You maintain it. It is a
navigation aid, not a specification.

**Authority.** The code is the truth. If the file contradicts the repo, the repo
wins — report `ARCH-DRIFT: <what disagrees>` and do not change code to match the doc.

**Bootstrap.** If the file does not exist, create it from the Appendix schema using
only rows verifiable from files you have actually read. Empty sections stay empty.
Never populate from project names, folder names, or my description of intent.

**Update triggers — exactly four. Nothing else touches this file.**
1. A new module with its own responsibility exists → add a MODULES row.
2. A public boundary changed (signature, signal, autoload contract, what crosses
   between modules) → edit the affected MODULES or DATAFLOW row.
3. A decision was made that constrains future work → append a DECISIONS entry.
4. A module was deleted or merged → remove or merge its row.

Bug fixes, internal refactors, tuning, and anything invisible from outside the
module do not touch this file.

**Timing.** The update ships in the same response as the code change. There is no
next session that remembers.

**Edit discipline.**
- Surgical edits only. Never reprint the file, reorder sections, reflow tables, or
  reword rows you aren't changing.
- IDs (`M-`, `INV-`, `D-`) are permanent. Assign the next unused number. Never
  renumber or reuse a retired ID.
- Supersede, don't delete: `D-003 SUPERSEDED BY D-011`.
- `owns` fields: 8 words maximum. If a module needs more, it owns too much — say so.

**Cap: 150 lines.** Check before appending. Compact in this order:

1. DECISIONS entries longer than 3 lines: move the full text to
   docs/decisions.md (append, keep ID order), leave a one-line stub in
   ARCHITECTURE.md:
   `D-054 2026-08-04: <one-line what and why> → docs/decisions.md`
   Size is the trigger, not age. A decision written today is eligible.
2. Superseded entries: stub only, no separate archive.
3. Merge MODULES rows for files that have always changed together.
4. Drop resolved OPEN items.

Never compact by making a stub vaguer than "what was chosen and why".
The full reasoning must survive in docs/decisions.md verbatim.

**Audit.** On `ARCH AUDIT`: list the repo's modules, compare against MODULES, report
additions, deletions, and stale `owns`/`depends` as a plain list. Make no edits
until I confirm.

---

### 9. Session handoff

On `HANDOFF`, or when a session is clearly ending, emit exactly this and nothing else:

```
STATE:    <what now works that didn't before>
TOUCHED:  <file: one-line summary per file>
OPEN:     <unresolved bugs / unverified assumptions>
NEXT:     <the single next action, phrased as a task>
CONTEXT:  <facts found this session not visible in the code>
```

Under 15 lines. Reference `ARCHITECTURE.md` IDs instead of restating. This is the
seed for the next chat.

---

## APPENDIX — Seed ARCHITECTURE.md

```markdown
# ARCHITECTURE

<!-- AGENT-MAINTAINED. Fixed schema — edit rows, never restructure. -->
<!-- CAP 150 lines. Over cap → compact per CLAUDE.md §8. -->
<!-- Code is authoritative. This file is a map, not a spec. -->

## STACK
Engine:
Language:
Build:
Target:

## MODULES
| id | path | owns | depends on | status |
|----|------|------|------------|--------|

<!-- status: stable | active | stub | deprecated -->

## DATAFLOW
<!-- one line per crossing: SOURCE -> SINK: what data, when -->
<!-- concrete, not abstract: name the signal/method and the trigger -->

## INVARIANTS
<!-- INV-n: must stay true globally; what breaks if violated -->

## DECISIONS
<!-- D-n YYYY-MM-DD: chose X over Y because Z -->

## OPEN
<!-- YYYY-MM-DD: unresolved question or known gap -->
```
