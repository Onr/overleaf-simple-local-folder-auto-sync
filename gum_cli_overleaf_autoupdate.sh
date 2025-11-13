#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "Missing dependency: %s\n" "$1" >&2
    exit 1
  fi
}

require_cmd gum
require_cmd git

GIT_KEY_STORE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/overleaf_autoupdate"
GIT_KEY_STORE_FILE="$GIT_KEY_STORE_DIR/git_key"

GIT_ASKPASS_DIR=""
declare -a GIT_AUTH_ENV=()

cleanup() {
  if [[ -n "$GIT_ASKPASS_DIR" && -d "$GIT_ASKPASS_DIR" ]]; then
    rm -rf "$GIT_ASKPASS_DIR"
  fi
}
trap cleanup EXIT

setup_git_auth_env() {
  local password="$1"

  if [[ -n "$GIT_ASKPASS_DIR" && -d "$GIT_ASKPASS_DIR" ]]; then
    rm -rf "$GIT_ASKPASS_DIR"
  fi

  GIT_ASKPASS_DIR=""
  GIT_AUTH_ENV=()

  if [[ -z "$password" ]]; then
    return
  fi

  GIT_ASKPASS_DIR=$(mktemp -d)
  local askpass_script="$GIT_ASKPASS_DIR/git-askpass.sh"
  cat <<'EOF' >"$askpass_script"
#!/usr/bin/env bash
printf '%s\n' "$OVERLEAF_PASSWORD"
EOF
  chmod +x "$askpass_script"

  GIT_AUTH_ENV=(
    "OVERLEAF_PASSWORD=$password"
    "GIT_TERMINAL_PROMPT=0"
    "GIT_ASKPASS=$askpass_script"
    "SSH_ASKPASS=$askpass_script"
  )
}

run_with_git_env() {
  if [[ "${#GIT_AUTH_ENV[@]}" -gt 0 ]]; then
    env "${GIT_AUTH_ENV[@]}" "$@"
  else
    "$@"
  fi
}

git_repo_cmd() {
  local project_dir="$1"
  shift
  run_with_git_env git -C "$project_dir" "$@"
}

git_spin() {
  local spinner="$1"
  local title="$2"
  shift 2
  if [[ "${#GIT_AUTH_ENV[@]}" -gt 0 ]]; then
    gum spin --spinner "$spinner" --title "$title" -- \
      env "${GIT_AUTH_ENV[@]}" git "$@"
  else
    gum spin --spinner "$spinner" --title "$title" -- \
      git "$@"
  fi
}

title() {
  gum style --border normal --margin "1 0" --padding "0 1" --border-foreground 212 "$1"
}

format_command_preview() {
  local parts=()
  local arg quoted
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    parts+=("$quoted")
  done
  local IFS=" "
  printf "%s" "${parts[*]}"
}

# Optional confirmation hook; defaults to quiet/no-op
require_command_approval() {
  # If interactive confirmations are desired, export GUM_REQUIRE_CONFIRM=1
  if [[ "${GUM_REQUIRE_CONFIRM:-0}" == "1" ]]; then
    local preview
    preview=$(format_command_preview "$@")
    if gum confirm "Run: $preview"; then
      return 0
    else
      gum style --foreground 196 "Canceled."
      exit 1
    fi
  fi
  return 0
}

prompt_repo_url() {
  gum input --placeholder "https://git@git.overleaf.com/<project-id>" --prompt "Overleaf Git URL: "
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

normalize_repo_url() {
  local input
  input=$(trim_whitespace "$1")

  local url=""
  if [[ "$input" =~ ^git[[:space:]]+clone[[:space:]]+(['\"]?)([^'\"[:space:]]+) ]]; then
    url="${BASH_REMATCH[2]}"
  else
    url="$input"
  fi

  printf "%s" "$url"
}

prompt_dest_dir() {
  local default_dir="$1"
  local answer
  answer=$(gum input --placeholder "$default_dir" --prompt "Clone into directory (default: $default_dir): ")
  if [[ -z "$answer" ]]; then
    printf "%s" "$default_dir"
  else
    printf "%s" "$answer"
  fi
}

prompt_password() {
  gum input --password --prompt "Overleaf password (input hidden): "
}

load_saved_git_key() {
  if [[ -f "$GIT_KEY_STORE_FILE" ]]; then
    tr -d '\r\n' <"$GIT_KEY_STORE_FILE"
  fi
}

save_git_key() {
  local password="$1"
  if [[ -z "$password" ]]; then
    return
  fi
  mkdir -p "$GIT_KEY_STORE_DIR"
  chmod 700 "$GIT_KEY_STORE_DIR"
  printf '%s' "$password" >"$GIT_KEY_STORE_FILE"
  chmod 600 "$GIT_KEY_STORE_FILE"
}

clear_saved_git_key() {
  if [[ -f "$GIT_KEY_STORE_FILE" ]]; then
    rm -f "$GIT_KEY_STORE_FILE"
  fi
}

ensure_git_key() {
  local saved=""
  if [[ -f "$GIT_KEY_STORE_FILE" ]]; then
    saved=$(load_saved_git_key)
  fi

  if [[ "${GUM_FORCE_PASSWORD_PROMPT:-0}" != "1" && -n "$saved" ]]; then
    gum style --foreground 244 "Using stored Overleaf Git key (set GUM_FORCE_PASSWORD_PROMPT=1 to re-enter)."
    printf '%s' "$saved"
    return
  fi

  gum style --foreground 244 "Overleaf Git authentication required. The value you enter will be stored for future runs."
  local password
  password=$(prompt_password)

  if [[ -n "$password" ]]; then
    save_git_key "$password"
    gum style --foreground 244 "Saved Git key to $GIT_KEY_STORE_FILE"
    printf '%s' "$password"
    return
  fi

  if [[ -n "$saved" || -f "$GIT_KEY_STORE_FILE" ]]; then
    clear_saved_git_key
    gum style --foreground 214 "Cleared stored Git key."
  else
    gum style --foreground 214 "No password entered; Git will rely on other credential helpers."
  fi

  printf '%s' ""
}

prompt_auto_choice() {
  gum choose "Start auto update loop now" "Skip for now"
}

prompt_start_action() {
  gum choose "Clone new Overleaf repo" "Sync existing local repo"
}

prompt_interval() {
  local current="${1:-60}"
  local value
  while true; do
    value=$(gum input --value "$current" --prompt "Auto update wait time in seconds: ")
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value > 0)); then
      printf "%s" "$value"
      return
    fi
    gum style --foreground 196 "Please enter a positive integer." >&2
  done
}

prompt_conflict_strategy() {
  gum choose \
    "remote (prefer Overleaf server on conflicts)" \
    "local (keep local files on conflicts)" \
    "ask (pause when conflicts happen)"
}

prompt_existing_repo_dir() {
  while true; do
    local answer
    answer=$(gum input --placeholder "$(pwd)" --prompt "Path to existing repo: ")
    if [[ -z "$answer" ]]; then
      gum style --foreground 196 "Path cannot be blank." >&2
      continue
    fi
    if [[ ! -d "$answer" ]]; then
      gum style --foreground 196 "Directory '$answer' does not exist." >&2
      continue
    fi
    if [[ ! -d "$answer/.git" ]]; then
      gum style --foreground 196 "'$answer' is not a Git repository." >&2
      continue
    fi
    local resolved
    resolved=$(cd "$answer" && pwd)
    printf "%s" "$resolved"
    return
  done
}

derive_strategy_flag() {
  local choice="$1"
  case "$choice" in
  remote*) printf "%s" "-Xtheirs" ;;
  local*) printf "%s" "-Xours" ;;
  *) printf "%s" "" ;;
  esac
}

auto_commit_local_changes() {
  local project_dir="$1"

  if [[ -z "$(git_repo_cmd "$project_dir" status --porcelain)" ]]; then
    return
  fi

  gum style --foreground 214 "Local changes detected. Creating auto commit..."
  git_repo_cmd "$project_dir" add -A
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  git_repo_cmd "$project_dir" commit -m "Auto commit ${timestamp}"
}

clone_repo() {
  local url="$1"
  local dest="$2"

  if [[ -d "$dest" ]]; then
    gum style --foreground 214 "Directory '$dest' already exists."
    gum confirm "Continue and reuse this directory?" || exit 1
  fi

  git_spin "line" "Cloning Overleaf project..." clone "$url" "$dest"
}

sync_once() {
  local project_dir="$1"
  local strategy_flag="$2"
  local branch
  branch=$(git_repo_cmd "$project_dir" rev-parse --abbrev-ref HEAD)

  auto_commit_local_changes "$project_dir"

  git_spin "pulse" "Fetching latest changes..." -C "$project_dir" fetch origin

  local pull_args=(-C "$project_dir" pull --no-edit --no-rebase origin "$branch")
  if [[ -n "$strategy_flag" ]]; then
    pull_args=(-C "$project_dir" pull --no-edit --no-rebase "$strategy_flag" origin "$branch")
  fi

  if ! git_spin "line" "Pulling updates..." "${pull_args[@]}"; then
    gum style --foreground 196 "Pull failed. Resolve conflicts and run sync again."
    return 1
  fi

  local status
  status=$(git_repo_cmd "$project_dir" status -sb)
  if [[ "$status" == *"[ahead"* ]]; then
    git_spin "dot" "Pushing local commits..." -C "$project_dir" push origin "$branch"
  fi
}

start_auto_sync() {
  local project_dir="$1"
  local interval="$2"
  local strategy="$3"

  gum style --foreground 212 "Starting auto update loop. Press Ctrl+C to stop."

  while true; do
    if sync_once "$project_dir" "$strategy"; then
      gum style --foreground 212 "Sync completed."
    else
      gum style --foreground 196 "Auto update encountered an error. Resolve issues and start again."
      return 1
    fi

    gum style --foreground 244 "Waiting ${interval}s before the next sync..."
    sleep "$interval"
  done
}

interactive_menu() {
  local project_dir="$1"
  local interval="$2"
  local strategy="$3"

  while true; do
    local selection
    selection=$(gum choose \
      "Run a sync now" \
      "Start auto update loop (Ctrl+C to stop)" \
      "Change auto update wait time (current: ${interval}s)" \
      "Change conflict strategy (current: $strategy)" \
      "Quit")

    case "$selection" in
    "Run a sync now")
      sync_once "$project_dir" "$strategy"
      ;;
    "Start auto update loop (Ctrl+C to stop)")
      start_auto_sync "$project_dir" "$interval" "$strategy"
      ;;
    "Change auto update wait time"*)
      interval=$(prompt_interval "$interval")
      ;;
    "Change conflict strategy"*)
      strategy_choice=$(prompt_conflict_strategy)
      strategy=$(derive_strategy_flag "$strategy_choice")
      ;;
    "Quit")
      gum style --foreground 212 "All done."
      exit 0
      ;;
    esac
  done
}

main() {
  title "Overleaf Git setup"

  local action
  action=$(prompt_start_action)

  local dest_dir=""
  local repo_password=""
  local repo_url=""
  local needs_clone=0
  if [[ "$action" == "Clone new Overleaf repo" ]]; then
    local repo_input
    while true; do
      repo_input=$(prompt_repo_url)
      repo_url=$(normalize_repo_url "$repo_input")
      [[ -n "$repo_url" ]] && break
      gum style --foreground 196 "URL cannot be blank."
    done

    local repo_basename
    repo_basename=$(basename "$repo_url")
    repo_basename="${repo_basename%.git}"

    dest_dir=$(prompt_dest_dir "$repo_basename")
    needs_clone=1
  else
    dest_dir=$(prompt_existing_repo_dir)
    gum style --foreground 212 "Using existing repository at $dest_dir"
    gum style --foreground 244 "Stored credentials are used when available; export GUM_FORCE_PASSWORD_PROMPT=1 to re-enter."
  fi

  repo_password=$(ensure_git_key)
  setup_git_auth_env "$repo_password"

  if ((needs_clone)); then
    clone_repo "$repo_url" "$dest_dir"
  fi

  title "Sync preferences"
  local conflict_choice
  conflict_choice=$(prompt_conflict_strategy)
  local strategy_flag
  strategy_flag=$(derive_strategy_flag "$conflict_choice")

  local interval
  interval=$(prompt_interval 60)

  local auto_choice
  auto_choice=$(prompt_auto_choice)

  if [[ "$auto_choice" == "Start auto update loop now" ]]; then
    (
      cd "$dest_dir"
      start_auto_sync "$(pwd)" "$interval" "$strategy_flag"
    )
  fi

  (
    cd "$dest_dir"
    interactive_menu "$(pwd)" "$interval" "$strategy_flag"
  )
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
