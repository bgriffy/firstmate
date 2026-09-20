// Firstmate's /toggle-no-mistakes command: shows whether automatic no-mistakes
// validation is on or off for the active home and lets the captain leave it or
// switch it.
//
// Verified against Pi 0.86.1, which exposes registerCommand, the generic
// ctx.ui.select dialog (usable in both TUI and RPC modes), ctx.hasUI, and
// sendMessage with nextTurn delivery. Two choices need no search or scrolling,
// so this stays on Pi's documented selector rather than a custom component.
//
// This file is only the dialog. bin/fm-validation-decision.sh is the single
// owner of the preference - its value vocabulary, its atomic replacement under
// the active home's config/, and its refusal inside a secondmate home, where
// the value is inherited from the primary - and docs/configuration.md
// "Automatic no-mistakes validation" owns the operator-facing contract, so
// nothing here reads or writes the file directly. ./lib/
// fm-toggle-no-mistakes-choices.ts owns the dialog's wording and how a pick is
// interpreted.
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { runCommandAsync } from "./lib/fm-async-exec.ts";
import {
  buildToggleQuestion,
  describeChange,
  parseAutoValidation,
  resolveToggleChoice,
  type AutoValidation,
} from "./lib/fm-toggle-no-mistakes-choices.ts";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const decisionScript = join(fmRoot, "bin", "fm-validation-decision.sh");
const TOGGLE_MESSAGE_TYPE = "firstmate-toggle-no-mistakes";

// FM_HOME is passed explicitly so the script addresses the home this Pi
// session belongs to even when its own default would resolve elsewhere.
const scriptEnv = { ...process.env, FM_HOME: fmHome };

async function runMode(args: string[]): Promise<{ value: AutoValidation | null; detail: string }> {
  const result = await runCommandAsync("bash", [decisionScript, "mode", ...args], {
    cwd: fmRoot,
    env: scriptEnv,
  });
  const detail = (result.stderr || "").trim().replace(/^error:\s*/, "");
  if (result.status !== 0) return { value: null, detail: detail || `exited ${result.status ?? "without a status"}` };
  const value = parseAutoValidation(result.stdout || "");
  return { value, detail: value ? "" : detail || "the preference could not be read" };
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("toggle-no-mistakes", {
    description: "Show whether Firstmate always runs no-mistakes, and leave it or switch it.",
    handler: async (_args, ctx) => {
      // Print and JSON modes cannot prompt, and a toggle nobody confirmed must
      // never be applied, so there is nothing to do without a dialog.
      if (!ctx.hasUI) return;

      const current = await runMode(["get"]);
      if (!current.value) {
        ctx.ui.notify(`Could not read the automatic no-mistakes setting: ${current.detail}`, "error");
        return;
      }

      const question = buildToggleQuestion(current.value);
      const picked = await ctx.ui.select(question.title, [...question.options]);
      const outcome = resolveToggleChoice(current.value, question, picked);
      if (outcome.kind === "keep") {
        ctx.ui.notify(`Automatic no-mistakes stays ${current.value.toUpperCase()}.`, "info");
        return;
      }

      const written = await runMode(["set", outcome.value]);
      if (written.value !== outcome.value) {
        ctx.ui.notify(
          `Automatic no-mistakes stays ${current.value.toUpperCase()}; the change was not saved: ${written.detail || "the saved value did not read back"}`,
          "error",
        );
        return;
      }
      ctx.ui.notify(describeChange(written.value), "info");

      // The scripts read the preference themselves, so nothing depends on the
      // agent hearing about it; this only keeps its picture of the home current
      // and reminds it of the one follow-up the script cannot do for it.
      pi.sendMessage(
        {
          customType: TOGGLE_MESSAGE_TYPE,
          content:
            `The captain set this home's automatic no-mistakes validation to ${written.value} with /toggle-no-mistakes. ` +
            "bin/fm-validation-decision.sh owns what that means; briefs and promotions made from now on follow it. " +
            "If second mates are running, push the inherited value with bin/fm-config-push.sh.",
          display: false,
        },
        { deliverAs: "nextTurn" },
      );
    },
  });
}
