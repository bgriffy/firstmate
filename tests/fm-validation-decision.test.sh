#!/usr/bin/env bash
# Behavior tests for the deferred no-mistakes validation decision:
# bin/fm-validation-decision.sh (the preference and the decision lifecycle) and
# the surfaces that must agree with it - bin/fm-brief.sh, bin/fm-promote.sh,
# bin/fm-spawn.sh, and bin/fm-teardown.sh. tests/fm-crew-state.test.sh covers
# how bin/fm-crew-state.sh reads the task record.
#
# The contract under test: an absent preference behaves exactly as before the
# preference existed; with it off, a no-mistakes worker stops at a durable
# post-implementation decision point that only the captain's recorded words can
# answer, a yes leaves the no-mistakes contract in force, a no switches the same
# task to direct-PR, and neither silence, a restart, nor a stale status event
# ever stands in for that answer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

DECISION="$ROOT/bin/fm-validation-decision.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-decision)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

# A home whose backlog gate applies (a markdown backlog plus the tracked
# .tasks.toml), or, with `exempt`, one that keeps no backlog file at all.
make_home() {  # <name> [exempt]
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  if [ "${2:-}" != exempt ]; then
    cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fi
  make_stubs "$TMP_ROOT/$1" >/dev/null
  printf '%s\n' "$home"
}

run_in() {  # <home> <command> [args...]
  local home=$1
  shift
  PATH="$(dirname "$home")/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SEND_SETTLE=0 "$@" 2>&1
}

decision() {  # <home> <args...>
  local home=$1
  shift
  run_in "$home" "$DECISION" "$@"
}

fill_brief() {  # <file>
  local content
  content=$(cat "$1")
  content=${content//'{TASK}'/Make the widget blue.}
  content=${content//'{FIRSTMATE_SPEC}'/Change the widget color constant.}
  printf '%s\n' "$content" > "$1"
}

# A deferred ship task at its decision point: a real scaffolded brief, a task
# copy on its branch with one committed change, the task record fm-spawn would
# have written, an In-flight backlog row where the home keeps a backlog, and
# the worker's keyed decision-point event.
make_task() {  # <home> <id>
  local home=$1 id=$2 case_dir proj wt
  case_dir=$(dirname "$home")
  proj="$case_dir/project-$id"
  wt="$case_dir/wt-$id"
  printf 'off\n' > "$home/config/no-mistakes-auto"
  run_in "$home" "$BRIEF" "$id" proj --mode no-mistakes >/dev/null \
    || fail "could not scaffold the deferred brief for $id"
  fill_brief "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf 'blue\n' > "$wt/widget.txt"
  git -C "$wt" add widget.txt
  git -C "$wt" commit -qm "Make the widget blue"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "validation_decision=pending" "spawn_gen=s1.1.1"
  if [ -f "$home/data/backlog.md" ]; then
    (cd "$home" && tasks-axi add "$id" --title "Make the widget blue" --repo proj >/dev/null) \
      || fail "could not file the backlog item for $id"
    (cd "$home" && tasks-axi start "$id" >/dev/null) || fail "could not start the backlog item for $id"
  fi
  printf 'needs-decision [at=1700000000] [key=validation-decision]: implementation committed at abc1234; run or skip no-mistakes\n' \
    > "$home/state/$id.status"
  printf '%s\n' "$wt"
}

# tests/lib.sh's assert_grep matches fixed substrings; the contract lines here
# are machine-read whole, so they are asserted as exact lines.
assert_line() {  # <exact-line> <file> <msg>
  grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

assert_line_matches() {  # <extended-regex> <file> <msg>
  grep -E -- "$1" "$2" >/dev/null || fail "$3"
}

# refused <exit-status> <msg>: the command just run must have exited nonzero.
refused() {
  [ "$1" -ne 0 ] || fail "$2"
}

meta_field() {  # <home> <id> <key>
  sed -n "s/^$3=//p" "$1/state/$2.meta" | tail -n 1
}

words_file() {  # <home> <text>
  printf '%s\n' "$2" > "$1/captain-words.txt"
  printf '%s\n' "$1/captain-words.txt"
}

# --- preference -------------------------------------------------------------

test_absent_preference_is_automatic_and_changes_nothing() {
  local home out
  home=$(make_home default-on exempt)
  out=$(decision "$home" mode get)
  expect_code 0 $? "reading an absent preference must succeed: $out"
  assert_equals on "$out" "an absent preference must read as on"
  assert_absent "$home/config/no-mistakes-auto" "reading the preference created it"

  run_in "$home" "$BRIEF" compat-absent proj --mode no-mistakes >/dev/null || fail "absent-preference scaffold failed"
  printf 'on\n' > "$home/config/no-mistakes-auto"
  run_in "$home" "$BRIEF" compat-on proj --mode no-mistakes >/dev/null || fail "on-preference scaffold failed"
  assert_equals \
    "$(sed 's/compat-absent/ID/g' "$home/data/compat-absent/brief.md")" \
    "$(sed 's/compat-on/ID/g' "$home/data/compat-on/brief.md")" \
    "an absent preference must scaffold the same brief as an explicit on"
  assert_line "Delivery contract: mode=no-mistakes" "$home/data/compat-absent/brief.md" \
    "the automatic contract line changed"
  assert_no_grep "key=validation-decision" "$home/data/compat-absent/brief.md" \
    "an automatic brief mentions the deferred decision"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$home/data/compat-absent/brief.md" \
    "the automatic brief lost today's validation handoff"
  pass "an absent preference is automatic validation and scaffolds today's brief unchanged"
}

test_preference_is_replaced_atomically_and_refuses_bad_input() {
  local home out leftovers
  home=$(make_home persistence exempt)
  out=$(decision "$home" mode set off)
  expect_code 0 $? "setting the preference off must succeed: $out"
  assert_equals off "$out" "mode set must print the value it stored"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "the stored preference is wrong"
  assert_equals off "$(decision "$home" mode get)" "the stored preference did not read back"
  leftovers=$(find "$home/config" -name '.no-mistakes-auto.*' | wc -l | tr -d '[:space:]')
  assert_equals 0 "$leftovers" "an atomic replace left a staging file behind"

  out=$(decision "$home" mode set maybe)
  refused $? "an invalid value must be refused: $out"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "a refused write changed the stored preference"

  # A target that cannot be replaced as a regular file fails closed and leaves
  # whatever is there alone, rather than half-writing a new value.
  rm -f "$home/config/no-mistakes-auto"
  mkdir "$home/config/no-mistakes-auto"
  out=$(decision "$home" mode set on)
  refused $? "a non-regular preference path must refuse the write: $out"
  [ -d "$home/config/no-mistakes-auto" ] || fail "a refused write disturbed the existing path"
  out=$(decision "$home" mode get)
  refused $? "an unreadable preference must never read as a default: $out"
  rmdir "$home/config/no-mistakes-auto"

  printf 'sometimes\n' > "$home/config/no-mistakes-auto"
  out=$(decision "$home" mode get)
  refused $? "an unknown stored value must be refused, not defaulted: $out"
  assert_contains "$out" "accepted values are" "the refusal did not name the accepted values"
  out=$(run_in "$home" "$BRIEF" bad-pref proj --mode no-mistakes)
  refused $? "a no-mistakes scaffold must refuse an unreadable preference: $out"
  assert_absent "$home/data/bad-pref/brief.md" "a refused scaffold wrote a brief"
  pass "the preference is replaced atomically and an unreadable value is refused everywhere"
}

test_secondmate_home_inherits_and_refuses_a_local_toggle() {
  local home out
  home=$(make_home inherited exempt)
  printf 'mate-1\n' > "$home/.fm-secondmate-home"
  printf 'off\n' > "$home/config/no-mistakes-auto"
  out=$(decision "$home" mode set on)
  refused $? "a secondmate home must refuse a local toggle: $out"
  assert_contains "$out" "primary home" "the refusal did not send the captain to the primary home"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "a refused toggle changed the inherited value"
  assert_equals off "$(decision "$home" mode get)" "a secondmate home must still read its inherited value"

  # shellcheck source=bin/fm-config-inherit-lib.sh
  out=$(bash -c '. "$1"; fm_config_inherit_items' _ "$ROOT/bin/fm-config-inherit-lib.sh")
  assert_contains "$out" "config/no-mistakes-auto" "the preference is not declared inherited local material"
  pass "the preference is inherited material a secondmate home reads but never toggles"
}

# --- scaffolding ------------------------------------------------------------

test_off_defers_only_no_mistakes_briefs() {
  local home out brief
  home=$(make_home scaffold exempt)
  printf 'off\n' > "$home/config/no-mistakes-auto"

  run_in "$home" "$BRIEF" deferred-a proj --mode no-mistakes >/dev/null || fail "deferred scaffold failed"
  brief="$home/data/deferred-a/brief.md"
  assert_line "Delivery contract: mode=no-mistakes validation=deferred" "$brief" "the deferred contract line is missing"
  assert_grep "key=validation-decision" "$brief" "the deferred brief does not name the decision key"
  assert_grep "do NOT push, open a PR, start no-mistakes" "$brief" "the deferred brief does not stop the worker before delivery"
  assert_grep "silence, elapsed time, or a restart is never an answer" "$brief" "the deferred brief lets silence stand as an answer"
  assert_grep "NEVER pass \`--yes\`" "$brief" "the deferred brief lost the no-mistakes guidance its run path needs"
  assert_no_grep "When you believe it is complete, append \`done" "$brief" "the deferred brief still reports plain done"

  run_in "$home" "$BRIEF" direct-a proj --mode direct-PR >/dev/null || fail "direct-PR scaffold failed"
  assert_line "Delivery contract: mode=direct-PR" "$home/data/direct-a/brief.md" "direct-PR gained a validation contract"
  run_in "$home" "$BRIEF" local-a proj --mode local-only >/dev/null || fail "local-only scaffold failed"
  assert_line "Delivery contract: mode=local-only" "$home/data/local-a/brief.md" "local-only gained a validation contract"

  run_in "$home" "$BRIEF" override-a proj --mode no-mistakes --validation auto >/dev/null || fail "override scaffold failed"
  assert_line "Delivery contract: mode=no-mistakes" "$home/data/override-a/brief.md" "a per-task auto override was ignored"
  printf 'on\n' > "$home/config/no-mistakes-auto"
  run_in "$home" "$BRIEF" override-b proj --mode no-mistakes --validation deferred >/dev/null || fail "deferred override scaffold failed"
  assert_line "Delivery contract: mode=no-mistakes validation=deferred" "$home/data/override-b/brief.md" "a per-task deferred override was ignored"

  out=$(run_in "$home" "$BRIEF" refused-a proj --mode direct-PR --validation deferred)
  refused $? "deferring a mode that never runs no-mistakes must be refused: $out"
  out=$(run_in "$home" "$BRIEF" refused-b proj --scout --validation deferred)
  refused $? "a scout scaffold must refuse --validation: $out"
  pass "off defers only no-mistakes briefs, and --validation overrides one task"
}

test_spawn_records_the_pending_decision_and_flags_drift() {
  local case_dir home proj wt fakebin out
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-spawn
  printf 'off\n' > "$home/config/no-mistakes-auto"
  run_in "$home" "$BRIEF" spawndef proj --mode no-mistakes >/dev/null || fail "deferred scaffold failed"
  fill_brief "$home/data/spawndef/brief.md"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" spawndef "$proj" claude --mode no-mistakes --yolo off)
  expect_code 0 $? "a deferred no-mistakes spawn must succeed: $out"
  assert_equals pending "$(meta_field "$home" spawndef validation_decision)" "spawn did not record the pending decision"
  assert_equals no-mistakes "$(meta_field "$home" spawndef mode)" "spawn changed the recorded mode"
  assert_not_contains "$out" "notice: spawndef brief records validation" "an agreeing brief was flagged as drift"

  # The same brief under a preference that has since been switched back on is
  # still this task's contract, so the spawn proceeds and says so.
  run_in "$home" "$BRIEF" spawndrift proj --mode no-mistakes >/dev/null || fail "second deferred scaffold failed"
  fill_brief "$home/data/spawndrift/brief.md"
  printf 'on\n' > "$home/config/no-mistakes-auto"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" spawndrift "$proj" claude --mode no-mistakes --yolo off)
  expect_code 0 $? "a drifted deferred spawn must still succeed: $out"
  assert_contains "$out" "notice: spawndrift brief records validation=deferred" "preference drift was not surfaced"
  assert_equals pending "$(meta_field "$home" spawndrift validation_decision)" "the brief's contract did not govern the task record"

  # A preference this home cannot read is never quietly treated as either
  # answer: the spawn stops before a task record exists.
  printf 'sometimes\n' > "$home/config/no-mistakes-auto"
  mkdir -p "$home/data/spawnbad"
  cp "$home/data/spawndef/brief.md" "$home/data/spawnbad/brief.md"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" spawnbad "$proj" claude --mode no-mistakes --yolo off)
  refused $? "a no-mistakes spawn must refuse an unreadable preference: $out"
  assert_contains "$out" "accepted values are" "the spawn refusal did not name the accepted values"
  assert_absent "$home/state/spawnbad.meta" "a refused spawn wrote a task record"
  printf 'on\n' > "$home/config/no-mistakes-auto"

  run_in "$home" "$BRIEF" spawnauto proj --mode no-mistakes >/dev/null || fail "automatic scaffold failed"
  fill_brief "$home/data/spawnauto/brief.md"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" spawnauto "$proj" claude --mode no-mistakes --yolo off)
  expect_code 0 $? "an automatic no-mistakes spawn must succeed: $out"
  ! grep -q '^validation_' "$home/state/spawnauto.meta" || fail "an automatic task record gained a validation field"
  pass "spawn records a deferred brief's pending decision, surfaces drift, and leaves automatic tasks untouched"
}

test_promotion_defers_like_a_brief() {
  local home out
  home=$(make_home promote exempt)
  printf 'off\n' > "$home/config/no-mistakes-auto"
  run_in "$home" "$BRIEF" scout-a proj --scout >/dev/null || fail "scout scaffold failed"
  fill_brief "$home/data/scout-a/brief.md"
  fm_write_meta "$home/state/scout-a.meta" "window=firstmate:fm-scout-a" "worktree=$home" \
    "project=$home" "harness=claude" "kind=scout" "spawn_gen=s1.1.1"
  out=$(run_in "$home" "$PROMOTE" scout-a --mode no-mistakes --yolo off)
  expect_code 0 $? "a deferred promotion must succeed: $out"
  assert_contains "$out" "validation=deferred" "promotion did not report the deferred contract"
  assert_equals pending "$(meta_field "$home" scout-a validation_decision)" "promotion did not record the pending decision"
  assert_line "Delivery contract: mode=no-mistakes validation=deferred" "$home/data/scout-a/ship-instructions.md" \
    "the promoted worker did not receive the deferred contract"
  assert_line "Delivery contract: mode=no-mistakes validation=deferred" "$home/data/scout-a/brief.md" "a relaunched promoted worker would lose the deferred contract"
  pass "a scout promoted to no-mistakes stops at the same decision point as a briefed task"
}

# --- decision lifecycle -----------------------------------------------------

test_open_requires_a_real_decision_point() {
  local home wt out
  home=$(make_home open-guards exempt)
  wt=$(make_task "$home" guard-a)

  : > "$home/state/guard-a.status"
  out=$(decision "$home" open guard-a)
  refused $? "open must refuse before the worker reports its decision point: $out"
  assert_contains "$out" "has not reported its decision point" "the refusal did not name the missing report"

  # A plain done line is not the keyed report, so it never opens the decision.
  printf 'done [at=1700000001]: finished the widget\n' > "$home/state/guard-a.status"
  out=$(decision "$home" open guard-a)
  refused $? "a plain done event must not open the decision: $out"

  printf 'needs-decision [at=1700000002] [key=validation-decision]: implementation committed\n' > "$home/state/guard-a.status"
  printf 'scratch\n' > "$wt/uncommitted.txt"
  out=$(decision "$home" open guard-a)
  refused $? "open must refuse a task copy with uncommitted changes: $out"
  assert_contains "$out" "uncommitted changes" "the refusal did not name the uncommitted work"
  assert_equals '' "$(meta_field "$home" guard-a validation_head)" "a refused open recorded a reviewed commit"
  rm -f "$wt/uncommitted.txt"

  fm_write_meta "$home/state/auto-a.meta" "window=firstmate:fm-auto-a" "worktree=$wt" "kind=ship" "mode=no-mistakes"
  out=$(decision "$home" open auto-a)
  refused $? "an automatic task has no decision to open: $out"
  assert_contains "$out" "validates automatically" "the refusal did not explain that the task is automatic"
  pass "open refuses until a deferred worker has reported a clean, committed decision point"
}

test_answer_requires_the_captains_words_for_the_reviewed_commit() {
  local home wt out words head
  home=$(make_home answer-guards exempt)
  wt=$(make_task "$home" guard-b)
  words=$(words_file "$home" "Skip it, the change is trivial.")

  out=$(decision "$home" answer guard-b skip --decision-file "$words")
  refused $? "an answer before any review must be refused: $out"
  assert_contains "$out" "run bin/fm-validation-decision.sh open" "the refusal did not send firstmate to the review"
  assert_equals pending "$(meta_field "$home" guard-b validation_decision)" "a refused answer changed the decision"

  decision "$home" open guard-b >/dev/null || fail "open failed"
  head=$(meta_field "$home" guard-b validation_head)
  assert_equals "$(git -C "$wt" rev-parse HEAD)" "$head" "open did not record the reviewed commit"

  out=$(decision "$home" answer guard-b skip)
  refused $? "an answer with no recorded words must be refused: $out"
  : > "$home/empty.txt"
  out=$(decision "$home" answer guard-b skip --decision-file "$home/empty.txt")
  refused $? "an empty decision file must be refused: $out"
  assert_contains "$out" "silence is never an answer" "the refusal did not reject silence"
  printf '   \n' > "$home/blank.txt"
  out=$(decision "$home" answer guard-b skip --decision-file "$home/blank.txt")
  refused $? "a whitespace-only decision file must be refused: $out"
  out=$(decision "$home" answer guard-b maybe --decision-file "$words")
  refused $? "an answer other than run or skip must be refused: $out"

  # The captain was asked about one diff; a worker that kept committing is a
  # different diff, so the recorded answer must not reach it.
  printf 'green\n' > "$wt/widget.txt"
  git -C "$wt" commit -qam "Make the widget green instead"
  out=$(decision "$home" answer guard-b skip --decision-file "$words")
  refused $? "an answer for a commit the captain never reviewed must be refused: $out"
  assert_contains "$out" "moved from the reviewed commit" "the refusal did not name the moved commit"
  assert_equals pending "$(meta_field "$home" guard-b validation_decision)" "a stale answer skipped validation"
  assert_equals no-mistakes "$(meta_field "$home" guard-b mode)" "a stale answer changed the delivery mode"
  pass "only the captain's recorded words, for the commit firstmate reviewed, answer the decision"
}

test_skip_switches_the_same_worker_to_direct_pr() {
  local home out words inbox message
  home=$(make_home skip-path exempt)
  make_task "$home" skip-a >/dev/null
  decision "$home" open skip-a >/dev/null || fail "open failed"
  words=$(words_file "$home" "Agreed, skip no-mistakes for this one.")

  out=$(decision "$home" answer skip-a skip --decision-file "$words")
  expect_code 0 $? "recording a skip must succeed: $out"
  assert_equals skip "$(meta_field "$home" skip-a validation_decision)" "the skip was not recorded"
  assert_equals direct-PR "$(meta_field "$home" skip-a mode)" "a skipped task must become direct-PR for every later stage"
  assert_equals 1 "$(meta_field "$home" skip-a validation_answer_sent)" "delivery to the worker was not recorded"
  assert_equals off "$(meta_field "$home" skip-a yolo)" "recording the decision changed merge authority"

  inbox="$home/state/skip-a.inbox"
  message=$(cat "$inbox"/*.msg 2>/dev/null) || fail "the same worker received no continuation"
  assert_contains "$message" "SKIP no-mistakes" "the continuation did not state the decision"
  assert_contains "$message" "Delivery contract: mode=direct-PR" "the continuation did not carry the direct-PR contract"
  assert_contains "$message" "push only your \`fm/skip-a\` branch" "the continuation did not carry the direct-PR safety rule"
  assert_contains "$message" "normal local checks" "the continuation dropped the local checks"
  assert_line_matches "^resolved .*\[key=validation-decision\]" "$home/state/skip-a.status" "the answered decision is still open"

  assert_line "# Current validation decision contract" "$home/data/skip-a/brief.md" "a relaunch would not see the decision"
  assert_grep "> Agreed, skip no-mistakes for this one." "$home/data/skip-a/brief.md" "the captain's words were not kept"
  assert_equals "mode=direct-PR" \
    "$(bash -c '. "$1"; fm_validation_brief_contract_line "$2"' _ "$ROOT/bin/fm-validation-decision-lib.sh" "$home/data/skip-a/brief.md")" \
    "the brief's current contract is not the decided one"

  # An identical retry is a no-op, and a different answer never rewrites it.
  out=$(decision "$home" answer skip-a skip --decision-file "$words")
  expect_code 0 $? "an identical retry must succeed: $out"
  assert_contains "$out" "already recorded and delivered" "the retry re-delivered the answer"
  assert_equals 1 "$(find "$inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d '[:space:]')" "a retry sent the worker a second instruction"
  out=$(decision "$home" answer skip-a run --decision-file "$words")
  refused $? "a recorded decision must not be rewritten by a different answer: $out"
  assert_equals skip "$(meta_field "$home" skip-a validation_decision)" "a refused re-answer changed the decision"
  pass "a no switches the same worker to the direct-PR path, durably and exactly once"
}

test_run_keeps_the_ordinary_no_mistakes_path() {
  local home out words message
  home=$(make_home run-path exempt)
  make_task "$home" run-a >/dev/null
  decision "$home" open run-a >/dev/null || fail "open failed"
  words=$(words_file "$home" "Yes, run it.")

  out=$(decision "$home" answer run-a run --decision-file "$words")
  expect_code 0 $? "recording a run must succeed: $out"
  assert_equals run "$(meta_field "$home" run-a validation_decision)" "the run was not recorded"
  assert_equals no-mistakes "$(meta_field "$home" run-a mode)" "a yes must leave the task on no-mistakes"
  assert_contains "$out" "harness-specific no-mistakes invocation" "firstmate was not pointed at the ordinary validation trigger"
  message=$(cat "$home/state/run-a.inbox"/*.msg 2>/dev/null) || fail "the same worker received no continuation"
  assert_contains "$message" "RUN no-mistakes" "the continuation did not state the decision"
  assert_not_contains "$message" "mode=direct-PR" "a yes delivered the direct-PR contract"
  assert_equals "mode=no-mistakes" \
    "$(bash -c '. "$1"; fm_validation_brief_contract_line "$2"' _ "$ROOT/bin/fm-validation-decision-lib.sh" "$home/data/run-a/brief.md")" \
    "a relaunched worker would stop at the decision point again"
  pass "a yes leaves the ordinary no-mistakes path in force on the same worker"
}

test_an_interrupted_answer_is_finished_by_the_same_command() {
  local home out words
  home=$(make_home interrupted exempt)
  make_task "$home" retry-a >/dev/null
  decision "$home" open retry-a >/dev/null || fail "open failed"
  words=$(words_file "$home" "Skip it.")

  # The crash window after the decision was published but before the worker was
  # told: the record is decided and nothing reached the steering inbox.
  {
    grep -v -e '^validation_decision=' -e '^mode=' "$home/state/retry-a.meta"
    printf 'validation_decision=skip\nmode=direct-PR\n'
  } > "$home/state/retry-a.meta.new"
  mv "$home/state/retry-a.meta.new" "$home/state/retry-a.meta"
  assert_absent "$home/state/retry-a.inbox" "the fixture already delivered an instruction"

  out=$(decision "$home" answer retry-a skip --decision-file "$words")
  expect_code 0 $? "re-running the identical answer must finish delivery: $out"
  assert_equals 1 "$(meta_field "$home" retry-a validation_answer_sent)" "the retry did not record delivery"
  [ -n "$(cat "$home/state/retry-a.inbox"/*.msg 2>/dev/null)" ] || fail "the retry did not tell the worker"
  assert_line "# Current validation decision contract" "$home/data/retry-a/brief.md" \
    "the retry did not finish the relaunch contract"
  pass "an interrupted answer is completed by re-running the identical command"
}

# On Pi, the supervision branch shares the home with main. It may make a parked
# worker a verified captain wait, but it can never hold the captain's words, so
# it must never record an answer or change the standing preference - attended
# or away.
test_supervision_branch_never_answers_or_toggles() {
  local home out words
  home=$(make_home branch-actor exempt)
  make_task "$home" branch-a >/dev/null
  words=$(words_file "$home" "Skip it.")

  out=$(FM_SUPERVISION_ACTOR=branch decision "$home" open branch-a)
  expect_code 0 $? "the branch may open the decision point: $out"

  out=$(FM_SUPERVISION_ACTOR=branch decision "$home" answer branch-a skip --decision-file "$words")
  refused $? "the supervision branch must never record a validation decision: $out"
  assert_contains "$out" "supervision branch never performs this action" "the refusal did not name the role partition"
  assert_equals pending "$(meta_field "$home" branch-a validation_decision)" "a refused branch answer changed the decision"
  assert_equals no-mistakes "$(meta_field "$home" branch-a mode)" "a refused branch answer changed the delivery mode"

  out=$(FM_SUPERVISION_ACTOR=branch decision "$home" mode set on)
  refused $? "the supervision branch must never change the preference: $out"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "a refused branch toggle changed the preference"
  assert_equals off "$(FM_SUPERVISION_ACTOR=branch decision "$home" mode get)" "the branch must still be able to read the preference"
  pass "the Pi supervision branch can open a decision point but never answers it or toggles the preference"
}

test_status_lists_pending_decisions_for_recovery() {
  local home out
  home=$(make_home recovery exempt)
  make_task "$home" pend-a >/dev/null
  make_task "$home" pend-b >/dev/null
  decision "$home" open pend-b >/dev/null || fail "open failed"
  decision "$home" answer pend-b run --decision-file "$(words_file "$home" "Run it.")" >/dev/null || fail "answer failed"

  out=$(decision "$home" status)
  expect_code 0 $? "listing pending decisions must succeed: $out"
  assert_contains "$out" "pend-a validation_decision=pending" "a pending decision was not listed after a restart"
  assert_not_contains "$out" "pend-b" "an answered decision was listed as pending"
  out=$(decision "$home" status pend-b)
  assert_contains "$out" "validation_decision=run" "the per-task status did not report the recorded decision"
  pass "a restarted firstmate can list every decision still waiting on the captain"
}

# --- captain-held durability ------------------------------------------------

test_gated_home_holds_the_work_item_for_the_captain() {
  local home out words show
  if [ -z "$TASKS_AXI_BIN" ]; then
    pass "captain-held durability (skipped: tasks-axi not found)"
    return 0
  fi
  home=$(make_home gated)
  make_task "$home" held-a >/dev/null

  out=$(decision "$home" open held-a)
  expect_code 0 $? "open must hold the work item for the captain: $out"
  assert_contains "$out" "held: held-a is held for the captain" "open did not report the hold"
  show=$(cd "$home" && tasks-axi show held-a --full)
  assert_contains "$show" "hold_kind: captain" "the work item is not held for the captain"
  assert_line_matches "^captain-held \[key=validation-decision\]" "$home/state/held-a.status" \
    "the open status decision was not transferred to the captain's hold"

  # Re-opening after a restart is safe and keeps the one hold.
  out=$(decision "$home" open held-a)
  expect_code 0 $? "re-opening a held decision must succeed: $out"

  words=$(words_file "$home" "Go ahead and skip no-mistakes here.")
  out=$(decision "$home" answer held-a skip --decision-file "$words")
  expect_code 0 $? "answering a held decision must succeed: $out"
  show=$(cd "$home" && tasks-axi show held-a --full)
  assert_contains "$show" "Go ahead and skip no-mistakes here." "the captain's words were not recorded on the held item"
  assert_not_contains "$show" "state: done" "answering the decision closed work that has not shipped"
  assert_equals direct-PR "$(meta_field "$home" held-a mode)" "the held task did not switch to direct-PR"
  [ -n "$(cat "$home/state/held-a.inbox"/*.msg 2>/dev/null)" ] || fail "the same worker received no continuation"
  pass "where the backlog gate applies, the decision is a captain-held work item answered with the captain's words"
}

# --- current state and cleanup ----------------------------------------------

test_cleanup_refuses_a_pending_decision() {
  local home wt out
  home=$(make_home reads exempt)
  wt=$(make_task "$home" read-a)
  cat > "$(dirname "$home")/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$(dirname "$home")/fakebin/no-mistakes"

  out=$(run_in "$home" "$ROOT/bin/fm-teardown.sh" read-a)
  refused $? "cleanup must refuse a task whose decision is pending: $out"
  assert_contains "$out" "decision is still pending" "the refusal did not name the pending decision"
  assert_present "$home/state/read-a.meta" "a refused cleanup removed the task record"
  [ -f "$wt/widget.txt" ] || fail "a refused cleanup touched the unshipped work"
  pass "cleanup refuses a pending decision as unshipped work and leaves it untouched"
}

test_absent_preference_is_automatic_and_changes_nothing
test_preference_is_replaced_atomically_and_refuses_bad_input
test_secondmate_home_inherits_and_refuses_a_local_toggle
test_off_defers_only_no_mistakes_briefs
test_spawn_records_the_pending_decision_and_flags_drift
test_promotion_defers_like_a_brief
test_open_requires_a_real_decision_point
test_answer_requires_the_captains_words_for_the_reviewed_commit
test_skip_switches_the_same_worker_to_direct_pr
test_run_keeps_the_ordinary_no_mistakes_path
test_an_interrupted_answer_is_finished_by_the_same_command
test_supervision_branch_never_answers_or_toggles
test_status_lists_pending_decisions_for_recovery
test_gated_home_holds_the_work_item_for_the_captain
test_cleanup_refuses_a_pending_decision
