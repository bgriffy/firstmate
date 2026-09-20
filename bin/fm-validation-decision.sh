#!/usr/bin/env bash
# fm-validation-decision.sh - single owner of the deferred no-mistakes
# validation decision: the home preference that turns it on, and the durable
# post-implementation decision point it creates for one ship task.
#
# Usage:
#   fm-validation-decision.sh mode get
#   fm-validation-decision.sh mode set <on|off>
#   fm-validation-decision.sh open <task-id>
#   fm-validation-decision.sh answer <task-id> <run|skip> --decision-file <path>
#   fm-validation-decision.sh status [<task-id>]
#
# WHAT IT DECIDES. With config/no-mistakes-auto absent or `on`, a no-mistakes
# task validates automatically, exactly as it did before this script existed,
# and nothing here is involved. With it `off`, bin/fm-brief.sh and
# bin/fm-promote.sh hand the worker the deferred contract rendered by
# bin/fm-dod-lib.sh, bin/fm-spawn.sh records `validation_decision=pending`, and
# the worker commits, reports
# `needs-decision [key=validation-decision]`, and stops without pushing,
# opening a PR, or starting no-mistakes. From there only this script moves the
# task: the captain's answer either runs the ordinary no-mistakes path or
# switches the task to the direct-PR path. bin/fm-validation-decision-lib.sh
# holds the shared spellings; the `validation-decision` skill owns how
# firstmate reviews the diff and what it recommends.
#
# `mode get` prints `on` or `off`. `mode set` replaces the preference
# atomically in the ACTIVE home (FM_HOME, else this checkout) and prints the
# new value. It refuses inside a secondmate home: the preference is inherited
# primary-authoritative material (bin/fm-config-inherit-lib.sh), so a value
# written there would be overwritten at the next convergence; toggle it in the
# primary home, then push it with bin/fm-config-push.sh when live secondmates
# should pick it up before their next convergence. A task already scaffolded
# keeps the contract its brief recorded; the preference governs briefs and
# promotions made after the change.
#
# `open <task-id>` is firstmate's first act on the worker's decision-point
# event. It refuses unless the task is a no-mistakes ship task whose decision
# is still pending, the worker has reported the decision point, and the task
# copy is on a branch with nothing uncommitted. It then makes the question the
# captain's durably - where this home's backlog gate applies
# (bin/fm-backlog-transition-lib.sh), it holds the work item for the captain
# and transfers the open status decision to that hold through
# bin/fm-captain-hold.sh, so an idle worker reads as a verified captain wait
# rather than a suspected wedge - records the reviewed commit as
# `validation_head=`, and prints the review entry point
# (bin/fm-review-diff.sh owns the diff itself). Re-running it is safe and
# refreshes the recorded commit. A home exempt from the backlog gate keeps the
# open status decision as its durable record instead.
#
# `answer <task-id> <run|skip> --decision-file <path>` records the captain's
# own words (a non-empty file of at most 8192 bytes) and resumes the SAME
# worker. It refuses unless `open` recorded a commit that still equals the task
# copy's clean HEAD, so an answer can never cover a diff the captain was not
# asked about; re-run `open`, review, and ask again when it moved. In order it:
# releases the captain hold with those words (bin/fm-captain-hold.sh answer
# --release, where the backlog gate applies); appends the superseding
# `# Current validation decision contract` to data/<id>/brief.md so a relaunched
# worker receives the decided contract; publishes `validation_decision=run`, or
# `validation_decision=skip` together with `mode=direct-PR`, in the task's
# meta; and sends the continuation to the worker's steering inbox through
# bin/fm-send.sh, closing the status decision when it is still open there.
# `run` leaves the no-mistakes contract in force and firstmate then triggers
# validation through the ordinary harness-specific invocation
# (harness-adapters); `skip` delivers bin/fm-dod-lib.sh's direct-PR rule and
# Definition of done, after which the task is an ordinary direct-PR task for
# every later stage. Each step is idempotent, so an interrupted answer is
# finished by re-running the identical command; a recorded decision is final
# for the task, and a different answer is refused rather than rewritten.
# Nothing else in the repo may record `skip`: silence, a restart, elapsed time,
# standing yolo authority, away or quiet mode, and a stale status event are
# never an answer.
#
# `status` is read-only. With a task id it prints that task's decision record;
# with none it lists every task in this home whose decision is still pending,
# which is the recovery read after a restart.
#
# On Pi, `answer` and `mode set` are main-owned and refuse the supervision
# branch in every posture (bin/fm-lease-lib.sh's role partition, never
# away-relocated): the branch cannot hold the captain's words, and the away
# posture relocates standing authority, not a decision that was never standing.
# `open` and the read-only commands stay available to both actors, so a parked
# worker still becomes a verified captain wait while main is away.
#
# Merge authority, ask-user authority, security-sensitive escalation,
# unlanded-work protection, and no-mistakes branch custody are unchanged by
# every path here.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

DECISION_MAX_BYTES=8192
META_LOCK=
META_LOCK_HELD=0
TMP=

fail() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  return "$status"
}
trap cleanup EXIT

meta_value() {  # <key>
  sed -n "s/^$1=//p" "$META" | tail -n 1
}

# Replace the named keys in the task record under its own lock. Every other
# line is carried over untouched, so this can never drop a field another script
# owns.
meta_publish() {  # <key=value>...
  local pair filter=()
  META_LOCK=$(fm_meta_lock_path "$META") || fail "could not resolve the task record lock for $ID"
  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  fm_backlog_record_present "$META" "task record" "$STATE" \
    || fail "task record for $ID is unsafe or missing ($FM_BACKLOG_TRANSITION_ERROR)"
  for pair in "$@"; do
    filter+=(-e "^${pair%%=*}=")
  done
  TMP="$STATE/.$ID.meta.validation.${BASHPID:-$$}"
  grep -v "${filter[@]}" "$META" >"$TMP" || [ "$?" -eq 1 ] || fail "could not stage the task record for $ID"
  for pair in "$@"; do
    printf '%s\n' "$pair" >>"$TMP"
  done
  fm_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE" \
    || fail "task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)"
  TMP=
  fm_lock_release "$META_LOCK"
  META_LOCK_HELD=0
}

# Load and validate the one task this invocation addresses.
task_load() {  # <task-id>
  ID=$1
  fm_task_id_creation_valid "$ID" || fail "invalid task id"
  META="$STATE/$ID.meta"
  BRIEF="$DATA/$ID/brief.md"
  STATUS_FILE="$STATE/$ID.status"
  [ -f "$META" ] || fail "no task record for $ID at $META"
  KIND=$(meta_value kind)
  MODE=$(meta_value mode)
  DECISION=$(fm_validation_meta_decision "$META")
  WT=$(meta_value worktree)
}

require_deferred_task() {
  [ "$KIND" = ship ] || fail "task $ID is kind=${KIND:-unknown}; only a ship task carries a validation decision"
  case "$DECISION" in
    pending|run|skip) ;;
    '') fail "task $ID validates automatically (its record defers nothing); trigger no-mistakes through the ordinary validation step" ;;
    *) fail "task $ID records an unknown validation_decision '$DECISION'" ;;
  esac
}

# The clean, on-branch HEAD the decision is about. A dirty or detached task copy
# means the worker is not at the decision point, whatever its status says.
worktree_head() {
  local dirty
  [ -n "$WT" ] && [ -d "$WT" ] || fail "the task copy for $ID is missing: ${WT:-<unrecorded>}"
  git -C "$WT" symbolic-ref --quiet --short HEAD >/dev/null 2>&1 \
    || fail "the task copy for $ID is on a detached HEAD, so there is no committed branch to decide on"
  dirty=$(git -C "$WT" status --porcelain 2>/dev/null) || fail "cannot read the task copy for $ID"
  [ -z "$dirty" ] || fail "the task copy for $ID has uncommitted changes; the decision covers only a committed diff, so steer the worker to commit or discard them first"
  git -C "$WT" rev-parse --verify HEAD 2>/dev/null || fail "cannot resolve HEAD in the task copy for $ID"
}

# 0 applies, 1 exempt home, anything else refuses before any mutation.
backlog_gate() {
  local rc=0
  fm_backlog_transition_applies "$CONFIG" "$DATA" ship || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) fail "this home's backlog could not be resolved (${FM_BACKLOG_TRANSITION_ERROR:-unknown error}); the captain's decision cannot be recorded durably, so nothing was changed" ;;
  esac
}

command_mode() {
  local action=${1:-} value=${2:-}
  case "$action" in
    get)
      [ "$#" -eq 1 ] || { usage >&2; exit 2; }
      fm_validation_auto_read "$CONFIG"
      ;;
    set)
      [ "$#" -eq 2 ] || { usage >&2; exit 2; }
      fm_refuse_if_gate_agent
      fm_lease_forbid_branch "changing the automatic no-mistakes preference (fm-validation-decision mode set)"
      if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
        fail "this is a secondmate home, which inherits config/$FM_VALIDATION_PREFERENCE_FILE from the primary; change it in the primary home instead"
      fi
      fm_validation_auto_write "$CONFIG" "$value" || exit 1
      fm_validation_auto_read "$CONFIG"
      ;;
    *) usage >&2; exit 2 ;;
  esac
}

command_open() {
  local head verb gate_rc=0 short
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_refuse_if_gate_agent
  task_load "$1"
  require_deferred_task
  if [ "$DECISION" != pending ]; then
    echo "decided: $ID validation_decision=$DECISION (nothing to open)"
    return 0
  fi
  [ "$MODE" = no-mistakes ] || fail "task $ID is mode=${MODE:-unknown} with a pending validation decision; its record is inconsistent and must be reconciled by hand"
  verb=$(status_key_closing_verb "$STATUS_FILE" "$FM_VALIDATION_DECISION_KEY")
  case "$verb" in
    needs-decision|"${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") ;;
    *) fail "the worker for $ID has not reported its decision point (no open [key=$FM_VALIDATION_DECISION_KEY] event in $STATUS_FILE); wait for it rather than deciding on unfinished work" ;;
  esac
  head=$(worktree_head)
  short=$(git -C "$WT" rev-parse --short "$head")

  backlog_gate || gate_rc=$?
  if [ "$gate_rc" -eq 0 ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" hold "$ID" \
      --reason "run or skip no-mistakes for the committed work at $short - answer through bin/fm-validation-decision.sh answer" \
      >/dev/null || fail "could not hold $ID for the captain; the decision stays open in $STATUS_FILE and nothing else was changed"
    "$SCRIPT_DIR/fm-captain-hold.sh" complete "$ID" "$ID" >/dev/null \
      || fail "held $ID for the captain but could not transfer its open status decision; re-run this command"
  fi
  meta_publish "validation_head=$head"

  echo "open: $ID validation decision pending at $short"
  if [ "$gate_rc" -eq 0 ]; then
    echo "held: $ID is held for the captain until bin/fm-validation-decision.sh answer records the decision"
  else
    echo "held: no (${FM_BACKLOG_TRANSITION_SKIP:-this home is exempt from the backlog gate}); the open status decision is the durable record"
  fi
  echo "next: FM_HOME=$(printf '%q' "$FM_HOME") bin/fm-review-diff.sh $ID"
  echo "next: FM_HOME=$(printf '%q' "$FM_HOME") bin/fm-validation-decision.sh answer $ID <run|skip> --decision-file <captain-words-file>"
}

# The superseding contract a relaunched worker reads, appended once.
brief_append_decision() {  # <run|skip> <head> <decision-file>
  local choice=$1 head=$2 words=$3 tmp
  [ -f "$BRIEF" ] || fail "the brief for $ID is missing: $BRIEF"
  if grep -Fxq "$FM_VALIDATION_BRIEF_HEADING" "$BRIEF"; then
    return 0
  fi
  tmp="$DATA/$ID/.brief.md.validation.${BASHPID:-$$}"
  TMP=$tmp
  {
    cat "$BRIEF"
    printf '\n\n%s\n' "$FM_VALIDATION_BRIEF_HEADING"
    echo "This section supersedes every earlier brief instruction about the post-implementation validation decision and about delivery mode."
    echo "The decision was recorded at $(date -u +%Y-%m-%dT%H:%M:%SZ) for the committed work at $head, and it is final for this task."
    echo "The words recorded with it:"
    echo
    sed 's/^/> /' "$words"
    echo
    if [ "$choice" = run ]; then
      echo "Decision: run no-mistakes."
      echo "Your implementation is already committed, so do not report the decision point again; firstmate instructs you to run /no-mistakes, and the contract below is in force."
      echo
      fm_dod_block no-mistakes "$ID"
    else
      echo "Decision: skip no-mistakes and ship this task as a direct PR."
      echo "Do NOT run /no-mistakes. Run the project's normal local checks before you push."
      echo
      echo "# Current ship safety rule"
      fm_ship_rule_one direct-PR "$ID"
      echo
      fm_dod_block direct-PR "$ID"
    fi
  } >"$tmp" || fail "could not render the decided contract for $ID"
  mv "$tmp" "$BRIEF" || fail "could not publish the decided contract into $BRIEF"
  TMP=
}

# The continuation the current worker receives. It repeats the decided contract
# rather than pointing at the brief, because the worker already has the
# pre-decision brief loaded and a pointer would leave both in force.
write_instructions() {  # <run|skip> <path>
  local choice=$1 path=$2
  TMP="$path.${BASHPID:-$$}"
  {
    if [ "$choice" = run ]; then
      echo "Validation decision for $ID: RUN no-mistakes."
      echo "Your pre-decision wait is over. Do not push or open a PR yourself."
      echo "Firstmate sends the no-mistakes invocation next; when it arrives, follow your Definition of done's no-mistakes guidance through to \`done [at=<epoch>]: PR {url} checks green\`."
      echo "If you are relaunched before it arrives, wait for it rather than reporting the decision point again."
    else
      echo "Validation decision for $ID: SKIP no-mistakes. This task now ships as a direct PR."
      echo "The contract below replaces your no-mistakes Definition of done and rule 1; everything else in your brief carries over unchanged."
      echo "Run the project's normal local checks before you push."
      echo
      echo "# Current ship safety rule"
      fm_ship_rule_one direct-PR "$ID"
      echo
      fm_dod_block direct-PR "$ID"
    fi
  } >"$TMP" || fail "could not render the worker instructions for $ID"
  mv "$TMP" "$path" || fail "could not publish the worker instructions for $ID"
  TMP=
}

command_answer() {
  local choice words='' bytes head recorded gate_rc=0 instructions send_args=() verb
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  fm_refuse_if_gate_agent
  fm_lease_forbid_branch "recording a validation decision (fm-validation-decision answer)"
  task_load "$1"
  choice=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; words=${1:-} ;;
      --decision-file=*) words=${1#--decision-file=} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$choice" in
    run|skip) ;;
    *) fail "the decision must be run or skip (got '$choice')" ;;
  esac
  require_deferred_task
  [ -n "$words" ] || fail "--decision-file is required: the captain's own words are the only thing that answers this decision"
  [ -f "$words" ] && [ -r "$words" ] && [ ! -L "$words" ] || fail "the decision file is not a readable regular file: $words"
  bytes=$(wc -c <"$words" | tr -d '[:space:]')
  [ "$bytes" -gt 0 ] || fail "the decision file is empty; silence is never an answer"
  [ "$bytes" -le "$DECISION_MAX_BYTES" ] || fail "the decision file exceeds $DECISION_MAX_BYTES bytes"
  [ -n "$(tr -d '[:space:]' <"$words")" ] || fail "the decision file holds only whitespace; silence is never an answer"

  if [ "$DECISION" != pending ]; then
    [ "$DECISION" = "$choice" ] \
      || fail "task $ID already records validation_decision=$DECISION, which is final for the task; a later captain change of mind is ordinary steering, not a second answer"
    if [ "$(meta_value validation_answer_sent)" = 1 ]; then
      echo "answered: $ID validation_decision=$DECISION was already recorded and delivered"
      return 0
    fi
    head=$(meta_value validation_head)
  else
    [ "$MODE" = no-mistakes ] || fail "task $ID is mode=${MODE:-unknown} with a pending validation decision; its record is inconsistent and must be reconciled by hand"
    recorded=$(meta_value validation_head)
    [ -n "$recorded" ] || fail "no reviewed commit is recorded for $ID; run bin/fm-validation-decision.sh open $ID and review the diff before recording an answer"
    head=$(worktree_head)
    [ "$head" = "$recorded" ] || fail "the task copy for $ID moved from the reviewed commit $recorded to $head; re-run open, review the new diff, and ask again"
  fi

  backlog_gate || gate_rc=$?
  if [ "$gate_rc" -eq 0 ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" answer "$ID" --decision-file "$words" --release >/dev/null \
      || fail "could not record the captain's answer on $ID's held work item; nothing else was changed (run open first if the item was never held)"
  fi
  brief_append_decision "$choice" "$head" "$words"
  if [ "$choice" = skip ]; then
    meta_publish "validation_decision=skip" "mode=direct-PR"
  else
    meta_publish "validation_decision=run"
  fi

  instructions="$DATA/$ID/validation-decision-instructions.md"
  write_instructions "$choice" "$instructions"
  verb=$(status_key_closing_verb "$STATUS_FILE" "$FM_VALIDATION_DECISION_KEY")
  [ "$verb" != needs-decision ] || send_args=(--resolve-key "$FM_VALIDATION_DECISION_KEY")
  if ! "$SCRIPT_DIR/fm-send.sh" "$ID" ${send_args[@]+"${send_args[@]}"} "$(cat "$instructions")"; then
    fail "validation_decision=$choice is recorded for $ID, but the worker was not told; re-run this identical command to finish delivery"
  fi
  meta_publish "validation_answer_sent=1"

  echo "answered: $ID validation_decision=$choice recorded and delivered to the same worker"
  if [ "$choice" = run ]; then
    echo "next: trigger validation on $ID with the harness-specific no-mistakes invocation (harness-adapters)"
  else
    echo "next: $ID is now mode=direct-PR; expect \`done: PR <url>\`, then bin/fm-pr-check.sh $ID <PR url>"
  fi
}

status_line() {  # uses the loaded task
  local head sent
  head=$(meta_value validation_head)
  sent=$(meta_value validation_answer_sent)
  printf '%s validation_decision=%s mode=%s reviewed_head=%s answer_sent=%s\n' \
    "$ID" "${DECISION:-auto}" "${MODE:-unknown}" "${head:-none}" "${sent:-0}"
}

command_status() {
  local meta id
  if [ "$#" -eq 1 ]; then
    task_load "$1"
    status_line
    return 0
  fi
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_validation_meta_decision "$meta")" = pending ] || continue
    id=${meta##*/}
    task_load "${id%.meta}"
    status_line
  done
}

COMMAND=${1:-}
[ -n "$COMMAND" ] || { usage >&2; exit 2; }
shift
case "$COMMAND" in
  mode) command_mode "$@" ;;
  open) command_open "$@" ;;
  answer) command_answer "$@" ;;
  status) command_status "$@" ;;
  *) usage >&2; exit 2 ;;
esac
