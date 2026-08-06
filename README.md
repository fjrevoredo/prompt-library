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

## Working model

The repo is authoritative. The Espanso config directory is a disposable mirror.

1. Edit or add a `.yml` here.
2. Sync it into the live config:

   ```bash
   bash sync-prompts.sh
   ```

3. The prompt is live system-wide — no further steps.

Preview a sync without writing anything:

```bash
bash sync-prompts.sh --dry-run
```

Other flags:

| Flag | Effect |
|---|---|
| `--no-restart` | Sync and validate, but leave the running daemon alone |
| `--target DIR` | Sync somewhere else (basename must be `prompt-library`); implies no validate/restart |
| `-h`, `--help` | Usage |

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

| | Config directory | Copy tool | Espanso binary |
|---|---|---|---|
| macOS | `~/Library/Application Support/espanso` | `rsync` | `/Applications/Espanso.app/Contents/MacOS/espanso` |
| Windows 10/11 | `%APPDATA%\espanso` | `rsync` if present, else `robocopy /MIR` | `PATH`, else probed under `Program Files` / `%LOCALAPPDATA%\Programs` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/espanso` | `rsync` | `PATH` |

Resolution order is always `$ESPANSO_CONFIG_DIR` → `espanso path config` → the OS default above, so
the table is only the last resort.

### Windows notes

- **Run the script from Git Bash, MSYS2 or Cygwin.** It needs `bash` and `cygpath`; the script exits
  early with a clear message if `cygpath` is missing.
- **`rsync` is not part of Git for Windows.** When it's absent the script falls back to `robocopy`,
  which ships with Windows 10/11 — so no extra installation is needed. `robocopy /MIR` is the
  equivalent of `rsync --delete`, and its success exit codes (0–7) are handled explicitly.
- **WSL is a separate machine.** `uname` reports Linux there, so the script targets WSL's own
  `~/.config/espanso`, not the Windows Espanso. That's intentional — to manage a Windows install,
  use Git Bash rather than WSL.
- **Line endings are forced to LF** by `.gitattributes`. Without it a CRLF checkout would both break
  `bash sync-prompts.sh` and inject stray carriage returns into every expansion. If you cloned before
  that file existed, re-normalize with `git add --renormalize .`.
- The Windows installer's directory is not documented upstream, so the script probes a few plausible
  locations. If it can't find the binary, set `ESPANSO_BIN` or run `espanso env-path register`.

## Authoring conventions

- **Trigger prefix `:p.`** — `:p.review`, `:p.explain`. Namespaced, short, and no collision with
  the stock `:espanso` / `:date` / `:shell` matches in `match/base.yml`.
- **Every match needs a `label:`.** Espanso's search bar (`ALT+SPACE` by default) shows the label,
  and that search bar is the discovery interface for the library. Prefix them consistently:
  `"Prompt: ..."` for static, `"Prompt template: ..."` for forms.
- **One prompt per file**, filename matching the trigger — `:p.review` → `standard/code-review.yml`
  is fine; the point is a 1:1, greppable mapping.
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
  code, long descriptions — on their own line:

  ```yaml
  form: |
    Explain this [[language]] code:
    [[code]]
  ```

  Widening every field globally needs `max_form_width` / `max_form_height` in
  `config/default.yml`, which this repo deliberately does not manage (see below).
- Submit a form with `Ctrl+Enter`.

## New machine setup

1. Install Espanso ([macOS](https://espanso.org/docs/install/mac/) ·
   [Windows](https://espanso.org/docs/install/win/) · [Linux](https://espanso.org/docs/install/linux/))
   and let it register as a service: `espanso service register`, then `espanso start`.
2. Optional but convenient: `espanso env-path register` to put the CLI on `PATH`.
3. Clone this repo.
4. `bash sync-prompts.sh` — on Windows, from Git Bash.

## Reference

[Espanso documentation](https://espanso.org/docs/) — `AGENTS.md` has an annotated list of the specific
pages this setup depends on, so start there when something behaves differently than documented here.

## Scope boundary

This repo owns `<espanso config>/match/prompt-library/` and nothing else.

`config/default.yml` (machine-local Espanso settings) and `match/packages/` (installed Espanso
packages, which live *inside* `match/`) are never read, written, or deleted by the sync.
