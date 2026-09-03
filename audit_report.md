# UX Audit & Priority Improvement Plan: Nova TUI

## 1. UX Audit & Friction Identification

After an in-depth audit of the Nova codebase, focusing heavily on TUI interactions within the settings overlay (`/settings`), several high-friction UX issues were identified:

1. **Multiline System Prompt Editing is Broken:**
   - The "System Prompt" field is explicitly described as a multi-line editor (`Custom instructions prepended to every conversation.`).
   - However, when entering edit mode, pressing the `Enter` key immediately *commits* the text edit, instead of inserting a newline. This makes it impossible for users to type multiple lines of instructions directly in the TUI without resorting to external config file edits.

2. **Lack of Visual Cursor Feedback During Text Editing:**
   - While editing the System Prompt or the Bash Classifier URL, the text is drawn onto the screen, but the terminal cursor is not placed at the end of the text.
   - Users type blindly, relying solely on character appearance to know the editor is active, which breaks established terminal conventions and causes severe UX friction.

3. **Inconsistent UI Hinting:**
   - The UI hint says `Ctrl+S Save prompt · Esc Cancel`, but since `Enter` commits the text without saving, a user pressing `Enter` will suddenly drop out of edit mode without saving the changes to disk, which violates expectation.

## 2. Prioritized Improvement Plan

To resolve these issues and elevate the TUI to production-ready quality:

* **Priority 1: Enable Newline Insertion in System Prompt**
  - **Change:** Modify `src/tui/settings_lifecycle.zig` (`handleTextEditKey`). If `key.matches(vaxis.Key.enter)` and `state.edit_target == .system_prompt`, append a newline character (`\n`) to the buffer instead of committing. The user will use `Ctrl+S` to save or `Esc` to cancel. (For `.bash_classifier_url`, `Enter` can still commit, or we can make it consistent).
* **Priority 2: Render Terminal Cursor in Settings Inputs**
  - **Change:** Modify `src/tui/widgets/settings.zig` (`drawPrompt` and `drawAdvanced`). When `is_editing` is true, calculate the final `row` and `col` of the drawn text and set `surface.cursor = .{ .row = final_row, .col = final_col };`. This requires tracking where the text drawing ends.
