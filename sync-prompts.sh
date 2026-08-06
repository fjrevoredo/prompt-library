#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SOURCE_DIR="${SCRIPT_DIR}/espanso/match/prompt-library"
# The subtree name is also the safety guard: the sync target must end in this.
readonly SUBTREE_NAME="prompt-library"
readonly MACOS_ESPANSO_BIN="/Applications/Espanso.app/Contents/MacOS/espanso"
readonly USAGE="usage: bash sync-prompts.sh [--dry-run] [--no-restart] [--target DIR] [-h|--help]

Mirrors espanso/match/prompt-library/ from this repo into the live Espanso
config at <config>/match/prompt-library/, then validates and restarts Espanso.

  --dry-run       show what would change; touches nothing, skips restart
  --no-restart    sync and validate, but leave the running daemon alone
  --target DIR    sync somewhere else instead of the live config. The basename
                  must be '${SUBTREE_NAME}'. Implies no validate and no restart,
                  since Espanso does not read from there.
  -h, --help      print this message

Runs on macOS, Linux and Windows (Git Bash / MSYS2 / Cygwin). Copies with rsync
when available, otherwise with robocopy on Windows.

Environment: ESPANSO_BIN and ESPANSO_CONFIG_DIR override binary/config lookup."

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    # Git Bash reports MINGW64_NT-*, MSYS2 reports MSYS_NT-*, Cygwin CYGWIN_NT-*.
    # Note WSL reports Linux and has its own filesystem and its own Espanso, so
    # it is deliberately treated as plain unix, not as Windows.
    MINGW* | MSYS* | CYGWIN*) printf 'windows\n' ;;
    *) printf 'unix\n' ;;
  esac
}

# Windows-native tools (robocopy) and Windows-native programs (the Espanso CLI)
# speak drive-letter paths; the shell speaks POSIX ones. cygpath translates and
# exists in Git Bash, MSYS2 and Cygwin alike. Elsewhere both are no-ops.
to_posix_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath --unix -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    # Strip trailing separators: robocopy mis-parses a quoted "C:\dir\".
    cygpath --windows -- "${1%/}"
  else
    printf '%s\n' "$1"
  fi
}

# Espanso is not on PATH when installed as a macOS app bundle, and the Windows
# installer's directory is not documented upstream, so resolve explicitly and
# fail with actionable advice rather than assuming `espanso` works.
resolve_espanso_bin() {
  local platform="$1"
  local candidate

  if [[ -n "${ESPANSO_BIN:-}" ]]; then
    candidate="$(to_posix_path "${ESPANSO_BIN}")"
    [[ -x "${candidate}" ]] || die "ESPANSO_BIN is not executable: ${ESPANSO_BIN}"
    printf '%s\n' "${candidate}"
    return 0
  fi

  # `espanso env-path register` puts the CLI on PATH on both macOS and Windows,
  # so this is the common case for a properly set-up machine.
  local -a name_candidates=(espanso)
  if [[ "${platform}" == "windows" ]]; then
    # espanso.cmd is the documented entrypoint; espansod.exe is the daemon and
    # is only a fallback.
    name_candidates+=(espanso.cmd espanso.exe espansod.exe)
  fi

  local name
  for name in "${name_candidates[@]}"; do
    if candidate="$(command -v "${name}" 2>/dev/null)" && [[ -n "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  local -a path_candidates=()
  case "${platform}" in
    macos)
      path_candidates+=("${MACOS_ESPANSO_BIN}")
      ;;
    windows)
      # Not documented by Espanso; these are the plausible installer targets.
      # If none match, ESPANSO_BIN is the escape hatch.
      local dir
      for dir in "${PROGRAMFILES:-}" "${ProgramFiles:-}" "${LOCALAPPDATA:-}/Programs" "${APPDATA:-}/../Local/Programs"; do
        [[ -n "${dir}" ]] || continue
        dir="$(to_posix_path "${dir}")"
        path_candidates+=("${dir}/Espanso/espanso.exe" "${dir}/Espanso/espansod.exe")
      done
      ;;
  esac

  for candidate in "${path_candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  die "espanso binary not found. Run 'espanso env-path register' to put it on PATH, or set ESPANSO_BIN to its absolute path."
}

resolve_config_dir() {
  local espanso_bin="$1"
  local platform="$2"
  local from_cli

  # Espanso itself honours ESPANSO_CONFIG_DIR, so respecting it here keeps the
  # script and the daemon pointed at the same place.
  if [[ -n "${ESPANSO_CONFIG_DIR:-}" ]]; then
    to_posix_path "${ESPANSO_CONFIG_DIR}"
    return 0
  fi

  if from_cli="$("${espanso_bin}" path config 2>/dev/null)" && [[ -n "${from_cli}" ]]; then
    # Trim a trailing CR: a Windows-native espanso.exe emits CRLF line endings.
    from_cli="${from_cli%$'\r'}"
    to_posix_path "${from_cli}"
    return 0
  fi

  case "${platform}" in
    macos)
      printf '%s\n' "${HOME}/Library/Application Support/espanso"
      ;;
    windows)
      [[ -n "${APPDATA:-}" ]] || die "cannot locate the Espanso config dir: APPDATA is unset. Set ESPANSO_CONFIG_DIR."
      printf '%s\n' "$(to_posix_path "${APPDATA}")/espanso"
      ;;
    *)
      printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/espanso"
      ;;
  esac
}

# Mirroring with deletion is only safe because it is confined to our own
# subfolder. Refuse to run if the resolved target is anything else — a
# mis-resolved config dir must not be able to wipe match/base.yml or
# match/packages/ (which lives *inside* match/).
assert_target_is_subtree() {
  local target="$1"
  [[ "$(basename -- "${target%/}")" == "${SUBTREE_NAME}" ]] ||
    die "refusing to sync: target basename must be '${SUBTREE_NAME}', got '${target}'"
}

sync_with_rsync() {
  local target="$1"
  local dry_run="$2"
  local -a rsync_args

  # -rlt rather than -a: the payload is plain yml, and -a's ownership/permission
  # preservation (-pgoD) errors out against a Windows filesystem.
  rsync_args=(-rlt --delete --exclude '.DS_Store')

  if [[ "${dry_run}" == "1" ]]; then
    rsync_args+=(--dry-run --itemize-changes)
  else
    mkdir -p "${target}"
  fi

  rsync "${rsync_args[@]}" "${SOURCE_DIR}/" "${target%/}/"
}

sync_with_robocopy() {
  local target="$1"
  local dry_run="$2"
  local -a robocopy_args
  local rc=0

  # /MIR == /E + /PURGE, i.e. the equivalent of rsync --delete.
  robocopy_args=(
    "$(to_native_path "${SOURCE_DIR}")"
    "$(to_native_path "${target}")"
    /MIR /XF ".DS_Store" /NJH /NJS /NP /R:2 /W:2
  )

  if [[ "${dry_run}" == "1" ]]; then
    robocopy_args+=(/L)
  fi

  # robocopy uses exit codes 0-7 for success (bit flags for what it changed) and
  # >=8 for failure, so it must not be evaluated as a plain boolean under set -e.
  robocopy "${robocopy_args[@]}" || rc=$?
  ((rc < 8)) || die "robocopy failed with exit code ${rc}"
}

sync_prompts() {
  local target="$1"
  local dry_run="$2"
  local platform="$3"

  if command -v rsync >/dev/null 2>&1; then
    sync_with_rsync "${target}" "${dry_run}"
  elif [[ "${platform}" == "windows" ]] && command -v robocopy >/dev/null 2>&1; then
    sync_with_robocopy "${target}" "${dry_run}"
  elif [[ "${platform}" == "windows" ]]; then
    die "neither rsync nor robocopy found. robocopy ships with Windows 10/11 — check that C:\\Windows\\System32 is on PATH."
  else
    die "required command not found: rsync"
  fi
}

# `match list` parses the real on-disk config, so a zero exit is a genuine
# YAML + schema check with no extra dependencies.
validate_config() {
  local espanso_bin="$1"

  if ! "${espanso_bin}" match list --only-triggers >/dev/null; then
    die "Espanso rejected the config. The files are already copied into place; fix the yml in ${SOURCE_DIR} and re-run."
  fi
}

# `espanso restart` reports success even when the worker then dies on startup,
# so confirm the daemon is actually up. `status` exits 0 running / 4 not running.
verify_running() {
  local espanso_bin="$1"
  local attempt

  for attempt in 1 2 3 4 5; do
    if "${espanso_bin}" status >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "espanso is not running after restart. Check '${espanso_bin} log'; on macOS the usual cause is Secure Input being held by another app."
}

main() {
  local dry_run="0"
  local restart="1"
  local target_override=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run="1"
        ;;
      --no-restart)
        restart="0"
        ;;
      --target)
        [[ $# -ge 2 ]] || die "--target requires a directory argument"
        target_override="$2"
        shift
        ;;
      -h|--help)
        printf '%s\n' "${USAGE}"
        return 0
        ;;
      *)
        die "${USAGE}"
        ;;
    esac
    shift
  done

  [[ -d "${SOURCE_DIR}" ]] || die "source directory not found: ${SOURCE_DIR}"

  local platform
  platform="$(detect_platform)"

  # cygpath ships with Git Bash, MSYS2 and Cygwin alike. Without it we cannot
  # translate drive-letter paths, and rsync would read "C:\Users\..." as a
  # remote host:path spec and silently try to reach it over SSH.
  if [[ "${platform}" == "windows" ]] && ! command -v cygpath >/dev/null 2>&1; then
    die "cygpath not found. Run this from Git Bash, MSYS2 or Cygwin."
  fi

  local espanso_bin
  espanso_bin="$(resolve_espanso_bin "${platform}")"

  local target is_live
  if [[ -n "${target_override}" ]]; then
    target="$(to_posix_path "${target_override}")"
    is_live="0"
  else
    local config_dir
    config_dir="$(resolve_config_dir "${espanso_bin}" "${platform}")"
    # Sanity-check the resolution before building a --delete target out of it.
    # Espanso creates this directory on first launch.
    [[ -n "${config_dir}" ]] || die "could not resolve the Espanso config dir; set ESPANSO_CONFIG_DIR"
    [[ -d "${config_dir}" ]] || die "resolved Espanso config dir does not exist: ${config_dir}. Start Espanso once, or set ESPANSO_CONFIG_DIR."
    target="${config_dir}/match/${SUBTREE_NAME}"
    is_live="1"
  fi

  assert_target_is_subtree "${target}"

  printf 'platform: %s\n' "${platform}"
  printf 'syncing %s -> %s\n' "${SOURCE_DIR}" "${target}"
  sync_prompts "${target}" "${dry_run}" "${platform}"

  if [[ "${dry_run}" == "1" ]]; then
    printf 'dry run: nothing written, skipping validate and restart\n'
    return 0
  fi

  if [[ "${is_live}" != "1" ]]; then
    printf 'custom --target: skipping validate and restart (Espanso does not read from there)\n'
    return 0
  fi

  validate_config "${espanso_bin}"
  printf 'config validated\n'

  # auto_restart is on by default, but restarting explicitly makes the result
  # deterministic instead of depending on the file watcher.
  if [[ "${restart}" == "1" ]]; then
    "${espanso_bin}" restart
    verify_running "${espanso_bin}"
    printf 'espanso restarted and running\n'
  else
    printf 'skipping restart as requested\n'
  fi
}

main "$@"
