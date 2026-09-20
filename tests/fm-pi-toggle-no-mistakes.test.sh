#!/usr/bin/env bash
# Behavior tests for Pi's /toggle-no-mistakes command
# (.pi/extensions/fm-toggle-no-mistakes.ts).
#
# The tracked extension is loaded as Pi loads it - its default export is called
# with an ExtensionAPI - and its registered command is driven through a scripted
# ctx.ui. Nothing about the preference is faked: the command runs the real
# bin/fm-validation-decision.sh against an isolated home, so these cases prove
# the dialog and the stored value agree rather than pinning either alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-toggle-no-mistakes)
EXT="$ROOT/.pi/extensions/fm-toggle-no-mistakes.ts"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Pi toggle command test"; exit 0; }

# Drive the command once. The scripted pick is an option INDEX (0 leaves, 1
# switches), `cancel` dismisses the dialog, and `no-ui` runs without a dialog.
# Prints one JSON object describing what the captain saw and what was sent.
run_toggle() {  # <home> <pick: 0|1|cancel|no-ui>
  local home=$1 pick=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE='' FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' PLUGIN="$EXT" PICK="$pick" node --input-type=module <<'EOF'
const commands = new Map();
const sent = [];
const pi = {
  registerCommand(name, options) { commands.set(name, options); },
  sendMessage(message, options) { sent.push({ message, options }); },
};
const factory = (await import(process.env.PLUGIN)).default;
if (typeof factory !== "function") throw new Error("the extension does not default-export a factory");
await factory(pi);
const command = commands.get("toggle-no-mistakes");
if (!command) throw new Error("toggle-no-mistakes was not registered");
if (typeof command.description !== "string" || command.description === "") {
  throw new Error("the command carries no description");
}

const pick = process.env.PICK;
const prompts = [];
const notices = [];
const ctx = {
  hasUI: pick !== "no-ui",
  mode: pick === "no-ui" ? "print" : "tui",
  ui: {
    async select(title, options) {
      prompts.push({ title, options });
      if (pick === "cancel") return undefined;
      return options[Number(pick)];
    },
    notify(message, type) { notices.push({ message, type }); },
  },
};
await command.handler("", ctx);
console.log(JSON.stringify({ prompts, notices, sent }));
EOF
}

field() {  # <json> <jq-filter>
  printf '%s' "$1" | jq -r "$2"
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' "$home"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found for the Pi toggle command test"; exit 0; }

test_dialog_shows_the_current_value_and_offers_leave_or_switch() {
  local home out
  home=$(new_home default)
  out=$(run_toggle "$home" 0) || fail "the command failed on an unconfigured home: $out"
  assert_equals 1 "$(field "$out" '.prompts | length')" "the command must ask exactly one question"
  assert_contains "$(field "$out" '.prompts[0].title')" "is ON" "an unconfigured home must show automatic no-mistakes as ON"
  assert_equals 2 "$(field "$out" '.prompts[0].options | length')" "the dialog must offer exactly two choices"
  assert_contains "$(field "$out" '.prompts[0].options[0]')" "Leave it ON" "the first choice must keep the current value"
  assert_contains "$(field "$out" '.prompts[0].options[1]')" "Turn it OFF" "the second choice must name the other value"
  assert_absent "$home/config/no-mistakes-auto" "leaving the value wrote a preference"
  assert_equals 0 "$(field "$out" '.sent | length')" "leaving the value told the agent something changed"
  assert_contains "$(field "$out" '.notices[0].message')" "stays ON" "leaving the value was not confirmed"

  printf 'off\n' > "$home/config/no-mistakes-auto"
  out=$(run_toggle "$home" 0) || fail "the command failed on a home set to off: $out"
  assert_contains "$(field "$out" '.prompts[0].title')" "is OFF" "a home set to off must show OFF"
  assert_contains "$(field "$out" '.prompts[0].options[0]')" "Leave it OFF" "the choices did not follow the current value"
  assert_contains "$(field "$out" '.prompts[0].options[1]')" "Turn it ON" "the choices did not follow the current value"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "leaving the value changed it"
  pass "/toggle-no-mistakes shows the current value and offers to leave it or switch it"
}

test_switching_persists_in_the_active_home_and_round_trips() {
  local home out
  home=$(new_home switch)
  out=$(run_toggle "$home" 1) || fail "switching off failed: $out"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "switching off did not persist in the active home"
  assert_contains "$(field "$out" '.notices[0].message')" "now OFF" "switching off was not confirmed"
  assert_equals info "$(field "$out" '.notices[0].type')" "a successful switch was not an info notice"
  assert_equals 1 "$(field "$out" '.sent | length')" "the agent was not told the preference changed"
  assert_equals nextTurn "$(field "$out" '.sent[0].options.deliverAs')" "the change notice must never start a turn by itself"
  assert_contains "$(field "$out" '.sent[0].message.content')" "to off" "the change notice did not name the new value"
  [ -z "$(find "$home/config" -name '.no-mistakes-auto.*')" ] || fail "the switch left a staging file behind"

  out=$(run_toggle "$home" 1) || fail "switching back on failed: $out"
  assert_equals on "$(cat "$home/config/no-mistakes-auto")" "switching back on did not persist"
  assert_contains "$(field "$out" '.notices[0].message')" "now ON" "switching on was not confirmed"
  pass "/toggle-no-mistakes persists a switch in the active home, in both directions"
}

test_dismissal_and_no_dialog_change_nothing() {
  local home out
  home=$(new_home dismiss)
  printf 'off\n' > "$home/config/no-mistakes-auto"
  out=$(run_toggle "$home" cancel) || fail "dismissing the dialog failed: $out"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "a dismissed dialog changed the preference"
  assert_equals 0 "$(field "$out" '.sent | length')" "a dismissed dialog told the agent something changed"

  out=$(run_toggle "$home" no-ui) || fail "running without a dialog failed: $out"
  assert_equals 0 "$(field "$out" '.prompts | length')" "a session that cannot prompt still asked"
  assert_equals off "$(cat "$home/config/no-mistakes-auto")" "a session that cannot prompt changed the preference"
  pass "/toggle-no-mistakes changes nothing when the dialog is dismissed or cannot be shown"
}

test_failures_are_reported_without_claiming_a_change() {
  local home out
  home=$(new_home unreadable)
  printf 'sometimes\n' > "$home/config/no-mistakes-auto"
  out=$(run_toggle "$home" 1) || fail "the command crashed on an unreadable preference: $out"
  assert_equals 0 "$(field "$out" '.prompts | length')" "the command asked about a value it could not read"
  assert_equals error "$(field "$out" '.notices[0].type')" "an unreadable preference was not reported as an error"
  assert_equals sometimes "$(cat "$home/config/no-mistakes-auto")" "an unreadable preference was overwritten"

  home=$(new_home inherited)
  printf 'mate-1\n' > "$home/.fm-secondmate-home"
  out=$(run_toggle "$home" 1) || fail "the command crashed in a secondmate home: $out"
  assert_equals error "$(field "$out" '.notices[0].type')" "a refused switch was not reported as an error"
  assert_contains "$(field "$out" '.notices[0].message')" "stays ON" "a refused switch claimed a change"
  assert_contains "$(field "$out" '.notices[0].message')" "primary home" "the refusal did not send the captain to the primary home"
  assert_absent "$home/config/no-mistakes-auto" "a refused switch wrote a preference"
  assert_equals 0 "$(field "$out" '.sent | length')" "a refused switch told the agent something changed"
  pass "/toggle-no-mistakes reports an unreadable or inherited preference without claiming a change"
}

test_dialog_shows_the_current_value_and_offers_leave_or_switch
test_switching_persists_in_the_active_home_and_round_trips
test_dismissal_and_no_dialog_change_nothing
test_failures_are_reported_without_claiming_a_change
