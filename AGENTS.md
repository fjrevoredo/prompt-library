# AGENTS.md

## Repository role

This repository is the source of truth for Francisco's private library of reusable LLM prompts,
shipped as Espanso text expansions.

Espanso loads matches from the machine-local config directory:

- macOS: `~/Library/Application Support/espanso/match/`
- Windows: `%APPDATA%\espanso\match\` (i.e. `C:\Users\<user>\AppData\Roaming\espanso\match\`)
- Linux: `${XDG_CONFIG_HOME:-~/.config}/espanso/match/`

This repo owns exactly one subtree there: `match/prompt-library/`.

Never hardcode those paths in new code. `sync-prompts.sh` resolves the directory as
`$ESPANSO_CONFIG_DIR` → `espanso path config` → the per-OS default, and the defaults above are only
the last resort.

## Sync note

**Editing this repo does not change the live runtime.** Espanso reads from its own config
directory, so after any change to a prompt file, run:

```bash
bash sync-prompts.sh
```

Use `bash sync-prompts.sh --dry-run` first when you want to inspect the sync plan. The script
validates the resulting config and restarts Espanso itself; there is no separate reload step.

## Official documentation

Everything below was derived from these pages. **Check them first when something is missing, behaves
differently, or looks wrong** — Espanso is actively developed and these are the live docs, whereas
this file is a snapshot.

| Page | Why it matters here |
|---|---|
| [Configuration basics](https://espanso.org/docs/configuration/basics/) | Per-OS config directory paths; `config/` vs `match/` split |
| [Organizing matches](https://espanso.org/docs/matches/organizing-matches/) | All YAML under `match/` and its sub-folders is loaded; files starting with `_` are **not** loaded automatically |
| [Match basics](https://espanso.org/docs/matches/basics/) | `trigger:`, `replace:`, `label:` |
| [Forms](https://espanso.org/docs/matches/forms/) | `form:` / `form_fields:`, `choice` / `list` / `multiline`, `default:`, and the 100px field-width rule |
| [Variables](https://espanso.org/docs/matches/variables/) | If a prompt ever needs dynamic values (date, clipboard, shell) |
| [CLI basics](https://espanso.org/docs/command%20lIne/cli/) and [CLI reference](https://espanso.org/docs/command%20lIne/cli_list/) | `espanso path`, `match list`, `restart`, `service`, `env-path`. Note the upstream URL really does contain `command lIne` with a capital `I` — not a typo on our side |
| [Troubleshooting: secure input](https://espanso.org/docs/troubleshooting/secure-input/) | First stop when expansions stop firing on macOS |
| [Synchronization](https://espanso.org/docs/sync/) | Upstream's own take on git-syncing the config, for comparison with this repo's approach |
| [Install: macOS](https://espanso.org/docs/install/mac/) · [Windows](https://espanso.org/docs/install/win/) · [Linux](https://espanso.org/docs/install/linux/) | New-machine setup |
| [Packages](https://espanso.org/docs/packages/basics/) | Only relevant if the out-of-scope packaging decision is ever revisited |
| [match.schema.json](https://raw.githubusercontent.com/espanso/espanso/dev/schemas/match.schema.json) | The schema referenced by the header comment in every prompt file |

Verified against Espanso **2.4.0** on macOS. `espanso --help` and `espanso match list --help` are the
fastest ground truth for CLI flags; prefer running them over trusting this table.

## What is in scope here

- `espanso/match/prompt-library/standard/` — static prompts (`replace:`)
- `espanso/match/prompt-library/templates/` — form-backed prompts (`form:` + `form_fields:`)
- `sync-prompts.sh` — the only script
- `README.md` (human maintainer) and this file (agents)
- `.gitattributes` — forces LF; do not remove (see Windows notes below)

## Out of scope — do not touch

- `config/default.yml` in the Espanso config dir. Machine-local settings; this repo deliberately
  does not manage it. That includes `max_form_width` / `max_form_height`, so work around form
  width limits by layout instead (see below).

  Two options in it are nonetheless **load-bearing for every prompt here**, and are documented as a
  manual new-machine step in `README.md` rather than synced:

  ```yaml
  paste_shortcut_event_delay: 30   # stock 10ms; macOS drops the CMD modifier
  pre_paste_delay: 400             # stock 300ms
  ```

  If prompts expand as a bare `V`, check these before suspecting the yml.
- `match/base.yml` and `match/packages/` in the Espanso config dir. Note `packages/` lives
  **inside** `match/` — never widen the rsync target to `match/` itself.
- Packaging this as an Espanso external package. Considered and rejected: it adds a
  version/manifest layer with no benefit for a private single-user library.

## Authoring conventions

- Trigger prefix is **`:p.`** — e.g. `:p.check.plan`, `:p.check.impl`. Never introduce a prompt
  trigger without it, and never collide with the stock `:espanso` / `:date` / `:shell` matches.
- Related prompts get a shared second segment (`:p.check.*` is the review-your-own-work family), so
  typing the group prefix narrows the search bar to them. Put a new prompt in an existing group
  before inventing a new one.
- Every match must have a `label:`. Espanso's search bar surfaces the label, and that is the
  discovery interface for this library. Convention: `"Prompt: ..."` for static prompts,
  `"Prompt template: ..."` for form prompts.
- One prompt per file. Filename tracks the trigger; put the file in `standard/` or `templates/`
  depending on whether it uses `form:`.
- Use `.yml`, not `.yaml`.
- **Never prefix a filename with `_`** — Espanso treats those as includes and will not auto-load
  them, so the prompt silently won't exist.
- Keep the schema hint as the first line of every prompt file:

  ```yaml
  # yaml-language-server: $schema=https://raw.githubusercontent.com/espanso/espanso/dev/schemas/match.schema.json
  ```

### Form specifics

- `form:` and `replace:` are mutually exclusive. `form:` replaces `replace:`; setting both is an error.
- Placeholders are `[[name]]`; each is configured under `form_fields:`.
  Field types used here: plain (with optional `default:`), `type: choice` with `values:`, and
  `multiline: true`.
- A form input renders only 100px wide **unless it is the only thing on its line** — quoting the docs:
  *"Input fields are 100 pixels wide, but if their line contains no other text they expand to fit the
  width of the longest line of text plus input-boxes, in the form layout."* Any field expected to hold
  code or a paragraph must therefore sit alone on its own line in the `form:` template.
  `max_form_width` / `max_form_height` would fix this globally but live in `config/default.yml`, which
  is out of scope.

## Domain context for review prompts

Francisco's changes usually span **several merge requests in parallel**, not one:

- One or more **code MRs** — the feature itself.
- Optionally a **companion spec MR** in the separate capability-library repo that holds the OpenAPI
  spec. Any endpoint change means at least two MRs.
- Stacks build up from there, e.g. `backend → openapi → frontend`, or
  `dagster ← backend → openapi → frontend`.

Any prompt about reviewing changes must therefore accept **1+ code MRs and 0+ spec MRs** and point the
reviewer at cross-MR consistency — a prompt that reviews one diff in isolation is at the wrong
altitude for this workflow.

An Espanso form has fixed fields, so "N of something" can only be a multiline field. `review-mr.yml`
takes the whole stack in one `role: reference` list, ordered by dependency.

**Keep prompt bodies short.** These are nudges, not checklists: state the role to adopt, the context
the agent cannot infer, and what to lead with. An earlier version of `review-mr.yml` enumerated review
dimensions and rules across 3345 characters and was rejected as too complicated — a coding agent
already knows how to review code. Spend the words on what is specific to this workflow.

These prompts target **terminal coding agents**. Do not name a specific tool (`glab`, an API, a
particular skill) in a prompt body: tell the agent to obtain what it needs from repo context, its
available skills and tooling, and to stop and ask rather than guess. Naming the tool bakes in an
implementation detail that varies per machine and per agent.

## Cross-platform expectations

This library must work on macOS, Windows 10/11 and Linux. When touching `sync-prompts.sh`:

- Keep it POSIX-ish bash. Windows runs it under **Git Bash / MSYS2 / Cygwin**, where `cygpath` is
  required to translate between drive-letter and POSIX paths — the script dies early if it's absent.
- **`rsync` does not ship with Git for Windows.** The script falls back to `robocopy /MIR`
  (`/MIR` == `/E` + `/PURGE`, the equivalent of `rsync --delete`). Do not remove that fallback, and
  remember `robocopy` returns **0–7 on success** and ≥8 on failure, so it can never be tested as a
  plain boolean under `set -e`.
- Do not use `rsync -a` on a path that may be a Windows target: `-a` implies `-pgoD`, whose
  ownership/permission preservation fails there. The script uses `-rlt`, which is sufficient for
  plain yml.
- Never pass a drive-letter path to `rsync`. It reads `C:\...` as a remote `host:path` and silently
  tries SSH. Convert with `to_posix_path` first.
- WSL reports `Linux` from `uname` and has its own Espanso and filesystem, so it is deliberately
  treated as plain unix — not as a way to manage a Windows install.
- Prompt files must stay LF-only. `.gitattributes` enforces this because Espanso expands bodies
  verbatim, so a CRLF checkout injects `\r` into every expansion.

## Validation expectations

Use the smallest useful validation for the change.

```bash
bash sync-prompts.sh --dry-run    # expect only the intended adds/deletes
bash sync-prompts.sh              # expect "config validated" then "espanso restarted"
```

Then confirm the trigger actually registered. The CLI may not be on `PATH`:

```bash
# macOS
/Applications/Espanso.app/Contents/MacOS/espanso match list --only-triggers | grep '^:p\.'
# Windows (Git Bash) / Linux, once `espanso env-path register` has run
espanso match list --only-triggers | grep '^:p\.'
```

A non-zero exit from `espanso match list` means the config is broken — the sync script turns that
into a hard failure, but note the files are already on disk at that point, so fix the yml and re-run.

To test sync mechanics without touching the real config, use `--target`:

```bash
bash sync-prompts.sh --target /tmp/pl-test/prompt-library
```

The basename must be `prompt-library`; the script refuses anything else, and it also refuses a
resolved config directory that doesn't exist. Those guards are what make mirroring-with-deletion safe
here — do not remove or weaken them.

To exercise the Windows code path from macOS or Linux, stub `uname`, `cygpath` and `robocopy` onto a
minimal `PATH` (with no `rsync`) and run the script against a fake config tree. That is how the
robocopy fallback, the `cygpath` guard and the CR-trimming of `espanso path config` were verified
without a Windows machine.

Expansion behavior itself (does the text appear, does the form dialog render) can only be verified
by typing the trigger in a real text field. Ask Francisco to do that rather than claiming it works.

### When an expansion misbehaves, read the log before touching the yml

`espanso log` is the first move, not the last. A real incident: typing a trigger produced a literal
`V` followed by runaway backspaces, and the log showed macOS Secure Input had been acquired and the
worker had then panicked with `broken UI->Engine channel`. The prompt files were fine.

Mechanism worth knowing, because every prompt here is affected: `clipboard_threshold` defaults to 100
characters, so these prompts are *always* expanded via the clipboard, i.e. copy + inject Cmd+V. Any
condition that eats the Cmd modifier — Secure Input above all — degrades that into a bare `V`.

- `espanso log | grep -i 'secure input'` — Espanso's guess at the culprit app is documented as
  unreliable; do not repeat it as fact.
- `espanso status` — exit 0 running, exit 4 not running. A worker panic leaves it stopped, so verify
  before concluding a yml change had any effect at all.
- The user's emergency stop is pressing **ALT twice** (`toggle_key: ALT`).

Never set `force_mode: keys` on a prompt to avoid the clipboard. It is a real per-match option
(`force_mode: clipboard | keys` in the match schema), but `keys` injects each newline as a **Return
keypress**. These prompts are 10–70 lines, so in any chat input that submits the message dozens of
times mid-prompt. Multi-line prompts must go through the clipboard; fix the paste timing instead.

## Working expectations

- Keep changes focused and reviewable.
- Prompt bodies are the product: prefer explicit, well-structured instructions over terse ones.
- Update `README.md` when conventions, flags, or the repo layout change.
- Do not leave scratch prompt files or half-finished triggers behind — an unfinished `.yml` that
  syncs cleanly still becomes a live, triggerable expansion.
