// The question /toggle-no-mistakes asks, kept free of any terminal or process
// dependency so it stays testable. docs/configuration.md "Automatic
// no-mistakes validation" owns the operator-facing behavior, and
// bin/fm-validation-decision.sh owns the preference itself: this file never
// reads or writes it, it only words the dialog and interprets the pick.

/** The preference's two values, exactly as the owning script prints them. */
export type AutoValidation = "on" | "off";

/** What the captain's pick means for the stored preference. */
export type ToggleOutcome = { kind: "keep" } | { kind: "set"; value: AutoValidation };

/** One dialog: a title that states the current value, and its two choices. */
export interface ToggleQuestion {
  title: string;
  /** Always exactly two entries: leave it as it is, then switch it. */
  options: [string, string];
}

const DESCRIPTION: Record<AutoValidation, string> = {
  on: "always run no-mistakes when a crewmate finishes",
  off: "ask me after the changes are made whether to run no-mistakes",
};

function label(value: AutoValidation): string {
  return value.toUpperCase();
}

/**
 * Parses the owning script's `mode get` / `mode set` output. Anything other
 * than exactly one of the two values is unreadable, never a default: the
 * dialog must not claim a state Firstmate could not read.
 */
export function parseAutoValidation(stdout: string): AutoValidation | null {
  const value = stdout.trim();
  return value === "on" || value === "off" ? value : null;
}

/**
 * Builds the dialog for the current value. The choices are context-specific:
 * the first always keeps what is set now, and the second always names the
 * other value, so neither can be picked blind.
 */
export function buildToggleQuestion(current: AutoValidation): ToggleQuestion {
  const other: AutoValidation = current === "on" ? "off" : "on";
  return {
    title: `Automatic no-mistakes is ${label(current)} - ${DESCRIPTION[current]}`,
    options: [
      `Leave it ${label(current)}`,
      `Turn it ${label(other)} - ${DESCRIPTION[other]}`,
    ],
  };
}

/**
 * Resolves the pick against the question that produced it. A dismissed dialog
 * and any string the question did not offer both keep the current value, so
 * nothing but an explicit pick of the second choice ever changes it.
 */
export function resolveToggleChoice(
  current: AutoValidation,
  question: ToggleQuestion,
  picked: string | undefined,
): ToggleOutcome {
  if (picked !== undefined && picked === question.options[1]) {
    return { kind: "set", value: current === "on" ? "off" : "on" };
  }
  return { kind: "keep" };
}

/** The confirmation shown after the preference was written. */
export function describeChange(value: AutoValidation): string {
  return value === "on"
    ? "Automatic no-mistakes is now ON: a finished crewmate's changes always run no-mistakes."
    : "Automatic no-mistakes is now OFF: after a crewmate's changes are made, Firstmate reviews the diff, recommends whether to run no-mistakes, and asks you.";
}
