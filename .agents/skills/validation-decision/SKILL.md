---
name: validation-decision
description: >-
  Agent-only procedure for a ship task whose no-mistakes validation was deferred to the captain.
  Use when a worker reports `needs-decision [key=validation-decision]`, when `bin/fm-crew-state.sh` reads a task as `parked` from its `task-record`, when recovery finds a task recorded as `validation_decision=pending`, before recording or relaying the captain's run-or-skip answer, and when the captain asks to turn automatic no-mistakes on or off outside Pi's `/toggle-no-mistakes`.
  Owns how firstmate reviews the committed diff, what it recommends, and how it asks; `bin/fm-validation-decision.sh` owns every mechanic.
user-invocable: false
metadata:
  internal: true
---

# validation-decision

This skill is the single owner of firstmate's judgment at the deferred validation decision point.
`bin/fm-validation-decision.sh --help` owns the mechanics: the preference, the task record, the refusals, the ordering, and the retry rules.
`AGENTS.md` section 7 points here and does not restate this procedure.

The decision exists only for a task whose brief deferred it, which happens when this home's `config/no-mistakes-auto` is `off` or a captain instruction deferred that one task.
An automatic task never reaches this skill: trigger its validation exactly as section 7 describes.

## The one rule

Only the captain's own current words answer this decision.
Silence, elapsed time, a restart, a stale or repeated status event, standing `yolo` authority, and away or quiet mode never authorize skipping no-mistakes, and `yolo` does not authorize choosing for the captain in either direction.
When the captain cannot be reached, the task waits.

## Operating sequence

1. Run `bin/fm-validation-decision.sh open <id>`.
   A refusal is evidence, not an obstacle: a worker that reported plain `done`, left uncommitted changes, or has not reported at all is not at the decision point, so steer it to commit and report the keyed decision rather than deciding on unfinished work.
2. Read the complete committed diff with `bin/fm-review-diff.sh <id>`, not only its stat summary, together with the local evidence you already have: the brief, the worker's summary, the checks it ran and their results, and anything it flagged.
   Do not commission a reviewer, a second worker, or a manual audit for this; section 7 forbids inventing a review gate, and this is a recommendation, not a verdict.
3. Form a recommendation from the criteria below and state it with the concrete reasons that produced it.
4. Ask the captain in plain chat under section 9: what the change does, your recommendation to run or skip, the reasons in a few lines, and one yes-or-no question asking whether the captain agrees.
   Translate internal terms as section 9 requires, and keep this ask separate from any other decision.
5. Write the captain's exact words to a file and run `bin/fm-validation-decision.sh answer <id> <run|skip> --decision-file <path>`.
   Map those words to the choice honestly: agreeing with a recommendation to run is `run`, and an ambiguous reply is one clarifying question, never a guess.
   "Later" is not an answer to record here; the task simply keeps waiting.
6. On `run`, trigger validation on the same worker with the harness-specific invocation from `harness-adapters`, then continue section 7's Validate contract unchanged.
   On `skip`, the task is now an ordinary direct-PR task: wait for its `done: PR <url>` line and continue section 7 from there.

If `open` or `answer` reports that the task copy moved since the review, the diff you described to the captain is no longer the diff being decided.
Re-run `open`, review again, and ask again.

In a secondmate home the same sequence applies, and the ask and its answer travel over the parent channel like any other captain call.

## Recommending run or skip

Recommend from what the diff actually does, never from its size alone or from the file names.

Lean toward **skip** when all of these hold:

- The change is small and self-contained, and you can read every line of it with confidence.
- Its intent is unambiguous and the diff does exactly that and nothing else.
- It touches no behavior other code depends on, or that behavior is covered by checks the worker ran and that passed.
- A mistake would be cheap: easy to see, easy to revert, and harmless in the meantime.

Lean toward **run** when any of these hold:

- The change spans several files or subsystems, alters shared behavior, a public interface, a data format, a migration, or concurrency and ordering.
- It touches authentication, authorization, secrets, payments, personal data, or anything else security-sensitive.
- It is user-facing product behavior on a project whose standing posture asks for the full pipeline.
- It adds or changes logic without tests, the worker's checks failed, were skipped, or could not run, or the worker flagged uncertainty.
- The diff contains anything you did not expect from the brief, or you cannot explain a part of it.
- You are unsure. Doubt is a reason to run.

A recommendation to skip never lowers any other bar.
Destructive, irreversible, and security-sensitive work still escalates on its own terms, merge authority is unchanged, and a skipped task still runs the project's normal local checks before its PR.

## What to tell the captain

Lead with the outcome and the recommendation, then the reasons.
Name concrete facts from the diff: what changed, how far it reaches, what was tested, and what could go wrong.
Avoid restating the criteria above in the abstract; "three files in the billing path, no new tests" is a reason, "this is complex" is not.
End with the single question.

## Changing the preference

On Pi the captain changes the preference with `/toggle-no-mistakes`, which asks and writes it without involving you.
On every other primary harness, and whenever the captain asks in chat, read it with `bin/fm-validation-decision.sh mode get`, tell the captain the current value in plain words, and change it with `mode set <on|off>` only on an explicit instruction to do so.
After a change in the primary home, run `bin/fm-config-push.sh` when second mates are live so they pick it up before their next convergence.
The preference governs briefs and promotions made after the change; a task already dispatched keeps the contract its brief recorded.
When the captain wants one task handled differently from the standing preference, pass that task's `--validation <auto|deferred>` to `bin/fm-brief.sh` or `bin/fm-promote.sh` rather than flipping the preference.
