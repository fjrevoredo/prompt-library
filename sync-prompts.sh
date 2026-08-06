#!/usr/bin/env bash
# macOS and Linux. On Windows use sync-prompts.ps1 instead.
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

macOS and Linux only — on Windows use sync-prompts.ps1.

Environment: ESPANSO_BIN and ESPANSO_CONFIG_DIR override binary/config lookup."

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    # Git Bash reports MINGW64_NT-*, MSYS2 MSYS_NT-*, Cygwin CYGWIN_NT-*.
    # WSL reports Linux and has its own Espanso, so it is correctly 'unix'.
    MINGW* | MSYS* | CYGWIN*)
      die "this is the macOS/Linux script; on Windows run sync-prompts.ps1 instead"
      ;;
    *) printf 'unix\n' ;;
  esac
}

# Espanso is not on PATH when installed as a macOS app bundle, so resolve it
# explicitly rather than assuming `espanso` works.
resolve_espanso_bin() {
  local platform="$1"
  local candidate

  if [[ -n "${ESPANSO_BIN:-}" ]]; then
    [[ -x "${ESPANSO_BIN}" ]] || die "ESPANSO_BIN is not executable: ${ESPANSO_BIN}"
    printf '%s\n' "${ESPANSO_BIN}"
    return 0
  fi

  # `espanso env-path register` puts the CLI on PATH; the common case.
  if candidate="$(command -v espanso 2>/dev/null)" && [[ -n "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  if [[ "${platform}" == "macos" && -x "${MACOS_ESPANSO_BIN}" ]]; then
    printf '%s\n' "${MACOS_ESPANSO_BIN}"
    return 0
  fi

  die "espanso binary not found. Run 'espanso env-path register' to put it on PATH, or set ESPANSO_BIN to its absolute path."
}

resolve_config_dir() {
  local espanso_bin="$1"
  local platform="$2"
  local from_cli

  # Espanso itself honours ESPANSO_CONFIG_DIR, so respecting it here keeps the
  # script and the daemon pointed at the same place.
  if [[ -n "${ESPANSO_CONFIG_DIR:-}" ]]; then
    printf '%s\n' "${ESPANSO_CONFIG_DIR}"
    return 0
  fi

  if from_cli="$("${espanso_bin}" path config 2>/dev/null)" && [[ -n "${from_cli}" ]]; then
    printf '%s\n' "${from_cli}"
    return 0
  fi

  if [[ "${platform}" == "macos" ]]; then
    printf '%s\n' "${HOME}/Library/Application Support/espanso"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/espanso"
  fi
}

# `rsync --delete` is only safe because it is confined to our own subfolder.
# Refuse to run if the resolved target is anything else — a mis-resolved config
# dir must not be able to wipe match/base.yml or match/packages/ (which lives
# *inside* match/).
assert_target_is_subtree() {
  local target="$1"
  [[ "$(basename -- "${target%/}")" == "${SUBTREE_NAME}" ]] ||
    die "refusing to sync: target basename must be '${SUBTREE_NAME}', got '${target}'"
}

sync_prompts() {
  local target="$1"
  local dry_run="$2"
  local -a rsync_args

  rsync_args=(-a --delete --exclude '.DS_Store')

  if [[ "${dry_run}" == "1" ]]; then
    rsync_args+=(--dry-run --itemize-changes)
  else
    mkdir -p "${target}"
  fi

  rsync "${rsync_args[@]}" "${SOURCE_DIR}/" "${target%/}/"
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

  # Platform first: a Windows shell must be told to use the .ps1 rather than be
  # sent down a confusing "rsync not found" path.
  local platform
  platform="$(detect_platform)"

  require_command rsync
  [[ -d "${SOURCE_DIR}" ]] || die "source directory not found: ${SOURCE_DIR}"

  local espanso_bin
  espanso_bin="$(resolve_espanso_bin "${platform}")"

  local target is_live
  if [[ -n "${target_override}" ]]; then
    target="${target_override}"
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
  sync_prompts "${target}" "${dry_run}"

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
