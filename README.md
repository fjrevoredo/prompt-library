# prompt-library

Private source-of-truth repository for Francisco's reusable LLM prompts and prompt templates,
delivered as [Espanso](https://espanso.org) text expansions.

## Purpose

The same prompts get reused across Claude Code, pi, web chats and GitLab. They belong to no single
project repo, so this repo is their home. Espanso turns them into a keyboard-driven interface that
works in **any** text field on the machine, plus a form UI for prompts that need parameters filled in.

Prompts live under `espanso/match/prompt-library/`:

- `standard/` — fixed prompts, expanded verbatim
- `templates/` — form-backed prompts that pop up a dialog to fill in placeholders

## Current prompts

| Trigger | What it is | File |
|---|---|---|
| `:p.check.plan` | Plan self-check: clarify, audit against the codebase, edit the plan in place | `standard/check-plan.yml` |
| `:p.check.impl` | Implementation self-check: accuracy, completeness, run the tests | `standard/check-impl.yml` |
| `:p.review.mr` | **Form.** Nudge to review a merge-request *stack* as one change | `templates/review-mr.yml` |
| `:p.review.impl` | **Form.** Adversarial review of a plan's implementation, writes a findings report | `templates/review-impl.yml` |

Groups so far: `:p.check.*` is review-your-own-work, `:p.review.*` is review-someone's-change. Keep
new prompts inside an existing group where one fits, so typing the group prefix narrows the search bar.

### About `:p.review.mr`

Deliberately a **nudge, not a checklist**. A coding agent already knows how to review code; what it
can't know is that one change is split across repositories. So the prompt spends its words on the
senior-engineer framing, the shape of the stack, and "read the real diffs" — and leaves the reviewing
to the reviewer.

Its single field takes the whole stack as `role: reference`, one per line, in dependency order:

```
dagster:  !9
backend:  !123
openapi:  !45
frontend: !678
```

One multiline field is the only way an Espanso form can accept a variable number of MRs, and the line
order carries the stack shape. Written for **terminal coding agents**: it passes references rather
than diff text and never names a specific tool, telling the agent to get the diffs from repo context
or whatever skills and tooling it has, and to ask rather than guess.

### `:p.check.impl` vs `:p.review.impl`

Both concern a finished implementation, but they are for different agents:

- **`:p.check.impl`** — the agent that *did* the work checking itself, in the same session. Static
  text, no output file, fixes go straight into the code.
- **`:p.review.impl`** — a *fresh* agent reviewing someone else's completed plan adversarially. Takes
  the plan's path and writes a prioritized findings report to a new markdown file beside it
  (`docs/plan.md` → `docs/plan-review.md`), so the report can be handed to another agent to act on.

`:p.review.impl` is told to include only findings that matter — objectively wrong, out of scope,
contradicting or missing from the plan, poor quality, bad practice — and that a short report is a good
outcome rather than something to pad. Each finding carries a rationale and concrete references so the
recipient can confirm it independently.

## Working model

The repo is authoritative. The Espanso config directory is a disposable mirror.

1. Edit or add a `.yml` here.
2. Sync it into the live config — `bash sync-prompts.sh` on macOS and Linux,
   `.\sync-prompts.ps1` on Windows.
3. The prompt is live system-wide — no further steps.

Preview a sync without writing anything:

```bash
bash sync-prompts.sh --dry-run      # macOS / Linux
```
```powershell
.\sync-prompts.ps1 -DryRun          # Windows
```

Other flags, same meaning in both scripts:

| Flag | Effect |
|---|---|
| `--no-restart` / `-NoRestart` | Sync and validate, but leave the running daemon alone |
| `--target DIR` / `-Target DIR` | Sync somewhere else (basename must be `prompt-library`); implies no validate/restart |
| `-h`, `--help` / `-?` | Usage |

`ESPANSO_BIN` and `ESPANSO_CONFIG_DIR` override binary and config-dir lookup. Espanso honours
`ESPANSO_CONFIG_DIR` too, so the script and the daemon stay in agreement.

### What the sync does

`espanso/match/prompt-library/` → `<espanso config>/match/prompt-library/`, mirroring with deletion,
then `espanso match list` as a validation pass, then `espanso restart`.

Because it mirrors, deletions and renames in the repo propagate correctly. The script asserts that
the resolved target's basename is `prompt-library` before running, so a mis-resolved config directory
can't delete its way through anything else, and it refuses to run if the resolved config directory
doesn't exist.

The Espanso binary is often **not** on `PATH` (on macOS it lives inside the app bundle). The script
resolves it itself; `espanso env-path register` is the official way to put it on `PATH`.

## Platforms

There is **one script per platform family**, each written natively for its own environment rather than
one script emulating the other:

| | Script | Config directory | Copy tool | Espanso binary |
|---|---|---|---|---|
| macOS | `sync-prompts.sh` | `~/Library/Application Support/espanso` | `rsync` | `/Applications/Espanso.app/Contents/MacOS/espanso` |
| Linux | `sync-prompts.sh` | `${XDG_CONFIG_HOME:-~/.config}/espanso` | `rsync` | `PATH` |
| Windows 10/11 | `sync-prompts.ps1` | `%APPDATA%\espanso` | `robocopy /MIR` | `PATH`, else probed under `Program Files` / `%LOCALAPPDATA%\Programs` |

Both scripts take the same flags (`--dry-run` / `-DryRun` etc.), resolve the config directory in the
same order — `$ESPANSO_CONFIG_DIR` → `espanso path config` → the OS default above — and apply the same
`prompt-library` basename guard before deleting anything.

Run the `.sh` on macOS and Linux; it exits immediately with a pointer to the `.ps1` if started from a
Windows shell. WSL is *not* Windows for this purpose: `uname` reports Linux, WSL has its own Espanso
and filesystem, so the `.sh` correctly targets `~/.config/espanso` there.

### Windows notes

```powershell
.\sync-prompts.ps1 -DryRun
.\sync-prompts.ps1
```

- **No extra tooling needed.** PowerShell 5.1 and `robocopy` both ship with Windows 10/11. Nothing to
  install: no Git Bash, no `cygpath`, no `rsync`.
- If PowerShell blocks the script, run it for the session with
  `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.
- `robocopy /MIR` is the equivalent of `rsync --delete`; its success exit codes (0–7) are handled
  explicitly, since only ≥8 means failure.
- The Windows installer's directory is not documented upstream, so the script probes a few plausible
  locations. If it can't find the binary, set `ESPANSO_BIN` or run `espanso env-path register`.
- **Line endings are forced to LF** by `.gitattributes`, because Espanso expands prompt bodies
  verbatim and a CRLF checkout would inject stray carriage returns into every expansion. PowerShell
  runs LF scripts fine. If you cloned before that file existed, re-normalize with
  `git add --renormalize .`.

## Authoring conventions

- **Trigger prefix `:p.`** — `:p.check.plan`, `:p.check.impl`. Namespaced, short, and no collision
  with the stock `:espanso` / `:date` / `:shell` matches in `match/base.yml`. Group related prompts
  with a second dotted segment (`:p.check.*`) so the search bar filters them together.
- **Every match needs a `label:`.** Espanso's search bar (`ALT+SPACE` by default) shows the label,
  and that search bar is the discovery interface for the library. Prefix them consistently:
  `"Prompt: ..."` for static, `"Prompt template: ..."` for forms.
- **One prompt per file**, filename tracking the trigger — `:p.check.plan` →
  `standard/check-plan.yml`; the point is a 1:1, greppable mapping.
- `standard/` for fixed prompts, `templates/` for form prompts. Subfolders are free organization:
  Espanso loads every `.yml` under `match/` recursively.
- **Never prefix a filename with `_`.** Espanso treats `_`-prefixed files as includes and does not
  auto-load them.
- Standardize on `.yml` (`.yaml` also works, but pick one).
- Keep the schema comment at the top of each file for editor completion:

  ```yaml
  # yaml-language-server: $schema=https://raw.githubusercontent.com/espanso/espanso/dev/schemas/match.schema.json
  ```

### Form gotchas

- `form:` and `replace:` are **mutually exclusive**. The `form:` shorthand takes the place of
  `replace:`.
- A form input renders only 100px wide **unless the field is alone on its line**. The docs put it as:
  *"Input fields are 100 pixels wide, but if their line contains no other text they expand to fit the
  width of the longest line of text plus input-boxes, in the form layout."* Keep long fields — pasted
  code, long descriptions, and any `choice` whose values are longer than a word or two — on their own
  line, with the label on the line before:

  ```yaml
  form: |
    The merge requests, one per line as `role: reference`:
    [[mrs]]
  ```

  That is how `templates/review-mr.yml` lays out its field. Widening fields globally instead would
  need `max_form_width` / `max_form_height` in `config/default.yml`, which this repo does not manage
  (see below).
- Submit a form with `Ctrl+Enter`.

## New machine setup

1. Install Espanso ([macOS](https://espanso.org/docs/install/mac/) ·
   [Windows](https://espanso.org/docs/install/win/) · [Linux](https://espanso.org/docs/install/linux/))
   and let it register as a service: `espanso service register`, then `espanso start`.
2. Optional but convenient: `espanso env-path register` to put the CLI on `PATH`.
3. Clone this repo.
4. `bash sync-prompts.sh`, or `.\sync-prompts.ps1` on Windows.
5. **Set the paste timing by hand** in `<espanso config>/config/default.yml`. Not optional on macOS,
   and not managed by this repo:

   ```yaml
   paste_shortcut_event_delay: 30   # stock 10ms drops the CMD modifier
   pre_paste_delay: 400             # stock 300ms
   ```

   Every prompt here is far longer than the `clipboard_threshold` of 100 characters, so all of them
   are injected via the clipboard as copy + simulated Cmd+V. At the stock 10 ms, macOS intermittently
   loses the Cmd and the expansion arrives as a bare `V`. See Troubleshooting below.

## Troubleshooting

**Emergency stop.** Press **ALT twice** to toggle Espanso off (`toggle_key: ALT`, the stock default).
Use this the moment an expansion misbehaves — you do not have to quit the app you're typing in. Then
`espanso start` / `espanso status` from a terminal to recover.

### A literal `V` appears, then backspaces run away

This is macOS **Secure Input**, not a broken prompt file. Prompts here are far longer than the
`clipboard_threshold: 100` default, so Espanso always expands them via the clipboard: it copies the
text and injects Cmd+V. Under Secure Input the Cmd modifier is swallowed, leaving a bare `V`, while
the backspaces already queued to erase the trigger keep firing. The worker can then panic and die, so
Espanso stops responding entirely.

Diagnose and fix:

```bash
espanso log | grep -i 'secure input'   # confirms it, and names the suspected app
espanso workaround secure-input        # automates the usual fix
espanso status                         # 0 = running, 4 = not running
espanso start                          # after a worker crash
```

Espanso's guess about *which* app holds Secure Input is explicitly unreliable — it may name
`Terminal` when the real holder is something else. Common causes are a password field with focus, a
keychain prompt, and Terminal.app's **Secure Keyboard Entry** menu option
(`defaults read com.apple.Terminal SecureKeyboardEntry` → `1` means on).

Full detail: [Troubleshooting: secure input](https://espanso.org/docs/troubleshooting/secure-input/).

**The standing fix** is the paste timing from step 5 of new-machine setup:

```yaml
paste_shortcut_event_delay: 30
pre_paste_delay: 400
```

Confirm it is actually applied — the file is machine-local, so a fresh machine won't have it:

```bash
grep -vE '^\s*(#|$)' "$(espanso path config)/config/default.yml"
```

Do **not** reach for `force_mode: keys` on a prompt to dodge the clipboard. It is a valid per-match
option, but `keys` types each newline as a **Return keypress** — `:p.review.mr` alone holds 70 of
them, so in any chat input it would submit itself as ~70 separate messages. Clipboard injection is the
correct mechanism for multi-line prompts; the delays above are what make it reliable.

If a bare `V` still appears after all of that, the remaining levers are `backend: Clipboard` (stop
`auto` from second-guessing) and a higher `pre_paste_delay`.

### Other checks

- `espanso status` — is it even running? A crashed worker leaves it stopped. Both sync scripts
  verify this after restarting, so a failing sync means the daemon really is down.
- `espanso match list --only-triggers` — did your prompt load at all? If it's missing, the file is
  either invalid YAML, outside `match/`, or `_`-prefixed.
- `espanso log` — the worker logs config-parse errors here.

## Reference

[Espanso documentation](https://espanso.org/docs/) — `AGENTS.md` has an annotated list of the specific
pages this setup depends on, so start there when something behaves differently than documented here.

## Scope boundary

This repo owns `<espanso config>/match/prompt-library/` and nothing else.

`config/default.yml` (machine-local Espanso settings) and `match/packages/` (installed Espanso
packages, which live *inside* `match/`) are never read, written, or deleted by the sync.
