#!/usr/bin/env bash
#
# Installer for the Telegram job scanner.
#
# Installs a shared, agent-neutral backend into ~/.tgjobs and a thin /tgjobs
# command adapter into each LLM coding agent you choose (Claude Code, Codex,
# Gemini CLI, Cursor). Interactive by default; re-run any time to add another
# agent. Your state (~/.tgjobs/jobs/jobs.db) and config are never touched.
#
# Easiest (no clone):
#   curl -fsSL https://raw.githubusercontent.com/xcvmxc/telegram-job/main/install.sh | bash
#
# Non-interactive:
#   ./install.sh --lang en --agent claude,codex
#   curl -fsSL .../install.sh | bash -s -- --lang ru --agent all
#
# Update everything already installed (all agents at once, keeps state):
#   curl -fsSL .../install.sh | bash -s -- --update
#
set -euo pipefail

REPO="xcvmxc/telegram-job"
BRANCH="main"
TARBALL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

TGJOBS_HOME="${TGJOBS_HOME:-$HOME/.tgjobs}"   # absolute; adapters + configs use this
TS="$(date +%Y%m%d-%H%M%S)"

say()  { printf '  %s\n' "$1"; }
head() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- args ----------------------------------------------------------------
AGENTS=""; LANG_CHOICE=""; ASSUME_YES=0; DO_UPDATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENTS="${2:-}"; shift 2;;
    --agent=*) AGENTS="${1#*=}"; shift;;
    --lang) LANG_CHOICE="${2:-}"; shift 2;;
    --lang=*) LANG_CHOICE="${1#*=}"; shift;;
    --update) DO_UPDATE=1; shift;;
    -y|--yes) ASSUME_YES=1; shift;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 1;;
  esac
done

# Read a line from the real terminal even when the script is piped via curl.
tty_read() {  # tty_read VAR PROMPT
  local __v="$1" __p="$2" __ans=""
  # Probe by actually opening /dev/tty for write — the node can exist yet fail
  # to open (ENXIO "Device not configured") when there's no controlling tty.
  if { : > /dev/tty; } 2>/dev/null; then
    printf '%s' "$__p" > /dev/tty 2>/dev/null || true
    IFS= read -r __ans < /dev/tty 2>/dev/null || __ans=""
  fi
  printf -v "$__v" '%s' "$__ans"
}

head "Telegram job scanner — install"

# --- prerequisites -------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { say "✗ python3 is required."; exit 1; }
if ! command -v uv >/dev/null 2>&1; then
  say "⚠  'uv' is not installed — install it, then re-run:"
  say "     curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

# --- update mode: reuse what's already installed -------------------------
# `--update` refreshes the shared backend AND re-drops the adapter into every
# agent this skill was installed in (from installed.json), at the same language.
if [ "$DO_UPDATE" -eq 1 ]; then
  IJ="$TGJOBS_HOME/installed.json"
  [ -f "$IJ" ] || { say "✗ nothing to update — $IJ not found. Run the installer first."; exit 1; }
  AGENTS="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(",".join(d.get("agents",[])))' "$IJ")"
  LANG_CHOICE="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("lang","en"))' "$IJ")"
  ASSUME_YES=1
  [ -n "$AGENTS" ] || { say "✗ installed.json lists no agents."; exit 1; }
  say "Updating agents from installed.json: $AGENTS (language: $LANG_CHOICE)"
fi

# --- locate product files (local checkout or download) -------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "${SELF_DIR}" ] && [ -f "${SELF_DIR}/adapters/en/tgjobs.md" ]; then
  ROOT="${SELF_DIR}"
else
  command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 || { say "✗ curl and tar are required."; exit 1; }
  say "Downloading…"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "$TARBALL" | tar -xz -C "$TMP" || { say "✗ download failed."; exit 1; }
  ROOT="$(cd "$TMP"/*/ && pwd)"
fi
VER="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"

# --- detect agents -------------------------------------------------------
detect() { # detect NAME  -> echo "yes"/"no"
  case "$1" in
    claude) { command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; } && echo yes || echo no;;
    codex)  { command -v codex  >/dev/null 2>&1 || [ -d "$HOME/.codex"  ]; } && echo yes || echo no;;
    gemini) { command -v gemini >/dev/null 2>&1 || [ -d "$HOME/.gemini" ]; } && echo yes || echo no;;
    cursor) { command -v cursor >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1 || [ -d "$HOME/.cursor" ]; } && echo yes || echo no;;
  esac
}
D_claude=$(detect claude); D_codex=$(detect codex); D_gemini=$(detect gemini); D_cursor=$(detect cursor)

# --- choose language -----------------------------------------------------
if [ -z "$LANG_CHOICE" ] && [ "$ASSUME_YES" -eq 0 ]; then
  head "Language / Язык"
  say "1) English   2) Русский"
  tty_read _l "  Choose [1]: "
  case "$_l" in 2|ru|RU|Ru) LANG_CHOICE=ru;; *) LANG_CHOICE=en;; esac
fi
case "${LANG_CHOICE:-en}" in ru) LANG_CHOICE=ru;; *) LANG_CHOICE=en;; esac
say "Language: ${LANG_CHOICE}"

# --- choose agents -------------------------------------------------------
mark() { [ "$1" = yes ] && printf '[detected]' || printf '[not found]'; }
if [ -z "$AGENTS" ] && [ "$ASSUME_YES" -eq 0 ]; then
  head "Which agents should get /tgjobs?"
  say "1) Claude Code  $(mark "$D_claude")"
  say "2) Codex        $(mark "$D_codex")"
  say "3) Gemini CLI   $(mark "$D_gemini")"
  say "4) Cursor       $(mark "$D_cursor")"
  say "Enter numbers separated by space (e.g. \"1 2\"), 'all', or Enter for detected."
  tty_read _a "  Choose: "
  AGENTS="$_a"
fi
# Normalise selection -> space list of names
sel=""
add() { case " $sel " in *" $1 "*) ;; *) sel="$sel $1";; esac; }
if [ "$AGENTS" = all ]; then
  add claude; add codex; add gemini; add cursor
elif [ -z "$AGENTS" ]; then
  # No explicit choice -> only the agents actually present on this machine.
  if [ "$D_claude" = yes ]; then add claude; fi
  if [ "$D_codex"  = yes ]; then add codex;  fi
  if [ "$D_gemini" = yes ]; then add gemini; fi
  if [ "$D_cursor" = yes ]; then add cursor; fi
else
  for tok in $(printf '%s' "$AGENTS" | tr ',' ' '); do
    case "$tok" in
      1|claude) add claude;; 2|codex) add codex;;
      3|gemini) add gemini;; 4|cursor) add cursor;;
      *) say "(ignoring unknown agent: $tok)";;
    esac
  done
fi
sel="$(printf '%s' "$sel" | xargs || true)"
[ -n "$sel" ] || { say "✗ no agents selected — nothing to do."; exit 1; }
say "Agents: $sel"

# --- install shared backend into ~/.tgjobs -------------------------------
head "Installing backend → ${TGJOBS_HOME}"
mkdir -p "$TGJOBS_HOME/jobs/templates/en" "$TGJOBS_HOME/jobs/templates/ru" "$TGJOBS_HOME/telegram"
cp -f "$ROOT"/skill/jobs/*.py "$TGJOBS_HOME/jobs/"
cp -f "$ROOT"/templates/en/*.md "$TGJOBS_HOME/jobs/templates/en/"
cp -f "$ROOT"/templates/ru/*.md "$TGJOBS_HOME/jobs/templates/ru/"
cp -f "$ROOT"/skill/telegram/tg_scan.py "$TGJOBS_HOME/telegram/"
cp -f "$ROOT/VERSION" "$TGJOBS_HOME/VERSION" 2>/dev/null || true
printf 'telegram-job-scanner\ninstalled_at=%s\n' "$TS" > "$TGJOBS_HOME/.tgjobs-install"
say "backend + templates (en/ru) installed  (v${VER})"

# --- migrate an older ~/.claude product install --------------------------
if [ -f "$HOME/.claude/jobs/.jobscanner" ] && [ ! -f "$TGJOBS_HOME/jobs/config.json" ]; then
  head "Migrating previous install (~/.claude → ~/.tgjobs)"
  for pair in "jobs/config.json:jobs/config.json" "jobs/jobs.db:jobs/jobs.db" \
              "telegram/credentials.env:telegram/credentials.env" "telegram/jobscan.session:telegram/jobscan.session"; do
    src="$HOME/.claude/${pair%%:*}"; dst="$TGJOBS_HOME/${pair##*:}"
    [ -f "$src" ] && { mkdir -p "$(dirname "$dst")"; mv "$src" "$dst"; say "moved ${pair##*:}"; }
  done
fi

# --- adapter writers -----------------------------------------------------
BODY="$ROOT/adapters/$LANG_CHOICE"
# localized skill descriptions
if [ "$LANG_CHOICE" = ru ]; then
  DESC_JOBS="Просканировать Telegram-каналы пользователя на новые вакансии по его критериям и записать подходящие в Markdown. Триггеры: /tgjobs, «проверь вакансии»."
  DESC_SETUP="Настроить сканер вакансий Telegram: API-ключ, вход, рабочая папка. Триггер: /tgjobs-setup."
else
  DESC_JOBS="Scan the user's Telegram channels for new job posts matching their Search Criteria and write matches to a Markdown file. Trigger on /tgjobs or 'scan telegram jobs'."
  DESC_SETUP="Set up the Telegram job scanner: API key, login, job folder. Trigger on /tgjobs-setup."
fi

write_skill() { # DIR NAME DESC BODYFILE
  mkdir -p "$1"
  { printf -- '---\nname: %s\ndescription: %s\n---\n\n' "$2" "$3"; cat "$4"; } > "$1/SKILL.md"
}
write_gemini_toml() { # OUT DESC BODYFILE
  mkdir -p "$(dirname "$1")"
  { printf 'description = "%s"\nprompt = """\n' "$2"; cat "$3"; printf '\n"""\n'; } > "$1"
}

install_claude() {
  mkdir -p "$HOME/.claude/commands"
  cp -f "$BODY/tgjobs.md"       "$HOME/.claude/commands/tgjobs.md"
  cp -f "$BODY/tgjobs-setup.md" "$HOME/.claude/commands/tgjobs-setup.md"
  say "Claude Code: /tgjobs + /tgjobs-setup → ~/.claude/commands/"
}

install_codex() {
  for base in "$HOME/.agents/skills" "$HOME/.codex/skills"; do
    write_skill "$base/tgjobs"       tgjobs       "$DESC_JOBS"  "$BODY/tgjobs.md"
    write_skill "$base/tgjobs-setup" tgjobs-setup "$DESC_SETUP" "$BODY/tgjobs-setup.md"
  done
  say "Codex: skills → ~/.agents/skills/ (+ ~/.codex/skills/)"
  # config.toml needs network + writable_roots; don't auto-edit (TOML table hazard) — instruct.
  if [ -f "$HOME/.codex/config.toml" ] && grep -q 'sandbox_workspace_write' "$HOME/.codex/config.toml"; then
    say "Codex: config.toml already has [sandbox_workspace_write] — ensure network_access=true and \"$TGJOBS_HOME\" is in writable_roots."
  else
    say "Codex: add this to ~/.codex/config.toml (top-level keys ABOVE any [table]):"
    printf '      approval_policy = "on-request"\n      sandbox_mode   = "workspace-write"\n      [sandbox_workspace_write]\n      network_access = true\n      writable_roots = ["%s"]\n' "$TGJOBS_HOME"
  fi
}

install_gemini() {
  write_gemini_toml "$HOME/.gemini/commands/tgjobs.toml"       "$DESC_JOBS"  "$BODY/tgjobs.md"
  write_gemini_toml "$HOME/.gemini/commands/tgjobs-setup.toml" "$DESC_SETUP" "$BODY/tgjobs-setup.md"
  say "Gemini: /tgjobs + /tgjobs-setup → ~/.gemini/commands/"
  python3 - "$HOME/.gemini/settings.json" "$TGJOBS_HOME" <<'PY'
import json, sys, pathlib, shutil
f, home = pathlib.Path(sys.argv[1]), sys.argv[2]
try:
    data = json.loads(f.read_text()) if f.exists() else {}
except Exception:
    print("skip"); raise SystemExit
if not isinstance(data, dict): data = {}
if f.exists(): shutil.copyfile(f, str(f) + ".tgjobs.bak")
f.parent.mkdir(parents=True, exist_ok=True)
data.setdefault("security", {}).setdefault("folderTrust", {})["enabled"] = True
allowed = data.setdefault("tools", {}).setdefault("allowed", [])
for p in (f"run_shell_command(python3 {home}/jobs/scan.py)",
          f"run_shell_command(python3 {home}/jobs/config.py)",
          "run_shell_command(cat)"):
    if p not in allowed: allowed.append(p)
f.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print("merged")
PY
  say "Gemini: settings.json — folder trust + shell allowlist merged (backup .tgjobs.bak)"
}

install_cursor() {
  write_skill "$HOME/.cursor/skills/tgjobs"       tgjobs       "$DESC_JOBS"  "$BODY/tgjobs.md"
  write_skill "$HOME/.cursor/skills/tgjobs-setup" tgjobs-setup "$DESC_SETUP" "$BODY/tgjobs-setup.md"
  say "Cursor: skills → ~/.cursor/skills/"
  python3 - "$HOME/.cursor/permissions.json" "$TGJOBS_HOME" <<'PY'
import json, sys, pathlib, shutil
f, home = pathlib.Path(sys.argv[1]), sys.argv[2]
try:
    data = json.loads(f.read_text()) if f.exists() else {}
except Exception:
    print("skip"); raise SystemExit
if not isinstance(data, dict): data = {}
if f.exists(): shutil.copyfile(f, str(f) + ".tgjobs.bak")
f.parent.mkdir(parents=True, exist_ok=True)
al = data.setdefault("terminalAllowlist", [])
for p in (f"python3 {home}/jobs", f"python3 {home}/telegram", "cat"):
    if p not in al: al.append(p)
f.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print("merged")
PY
  say "Cursor: permissions.json — terminal allowlist merged (backup .tgjobs.bak)"
}

# --- install selected agents --------------------------------------------
for a in $sel; do
  head "Agent: $a"
  install_"$a"
done

# --- record what's installed (agents accumulate across runs) -------------
# `installed.json` is the source of truth for `--update`: it lists every agent
# the skill lives in so one update refreshes them all.
python3 - "$TGJOBS_HOME/installed.json" "$LANG_CHOICE" "$VER" "$TS" $sel <<'PY'
import json, sys, pathlib
f = pathlib.Path(sys.argv[1]); lang, ver, ts = sys.argv[2], sys.argv[3], sys.argv[4]
new = sys.argv[5:]
try:
    d = json.loads(f.read_text()) if f.exists() else {}
except Exception:
    d = {}
if not isinstance(d, dict): d = {}
agents = d.get("agents") if isinstance(d.get("agents"), list) else []
for a in new:
    if a not in agents: agents.append(a)
d.update({"agents": agents, "lang": lang, "version": ver, "updated_at": ts})
f.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY

head "Done"
say "Backend: ${TGJOBS_HOME}  (v${VER}, language: ${LANG_CHOICE})"
if [ "$DO_UPDATE" -eq 1 ]; then
  say "Updated: $sel"
else
  say "Next: open one of the agents above and run  /tgjobs-setup"
  say "Re-run any time to add another agent; /tgjobs will offer updates when available."
fi
