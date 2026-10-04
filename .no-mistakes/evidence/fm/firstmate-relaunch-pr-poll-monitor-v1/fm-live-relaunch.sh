#!/usr/bin/env bash
# live: real tmux (private socket), real fm-pr-check (real gh read-only), real fm-control relaunch, real watcher lib
set -u
ROOT=$1 TRACE=$2 ID=$3
URL=https://github.com/kunchenguid/firstmate/pull/6545
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR=$TD
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null; chmod -R u+w "$LAB" 2>/dev/null; rm -rf "/tmp/fm-$ID"+*; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "/tmp/fm-$ID"; }
trap cleanup EXIT
export FM_HOME=$LAB
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX
unset CLAUDE_CONFIG_DIR
# project + worktree inside lab
PROJ=$LAB/projects/proj; WT=$LAB/wt
git init -q -b main "$PROJ"; git -C "$PROJ" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$PROJ" worktree add -q -b "task-$ID" "$WT"
mkdir -p "$LAB/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nExercise relaunch for %s.\n\n## Firstmate spec\nPreserve the task.\n' "$ID" > "$LAB/data/$ID/brief.md"
# real tmux session with a real claude in the worktree
"$ROOT/bin/fm-claude-trust.sh" "$WT" "$PROJ"
T new-session -d -s lab -n "fm-$ID" -c "$WT" -x 200 -y 50 "bash"
T send-keys -t "lab:fm-$ID" "claude" Enter
sleep 10
echo "-- pane before:"; T capture-pane -p -t "lab:fm-$ID" | grep -v "^\s*$" | tail -4
cat > "$LAB/state/$ID.meta" <<M
window=lab:fm-$ID
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$ID
model=default
effort=default
M
printf '%s\n' "$$" > "$LAB/state/.lock"
printf '%s %s\n' "$$" "$TRACE" > "$LAB/state/.trace-context-effective"
verdict() {
  bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"
    if fm_pr_poll_snapshot_capture "$2" "$3" "$1/bin/fm-pr-poll.sh"; then echo authenticated-pr-poll
    elif fm_custom_check_snapshot_prepare "$2" "$3"; then fm_custom_check_snapshot_cleanup; echo custom-check
    else fm_custom_check_snapshot_cleanup; echo rejected-unauthenticated; fi' _ "$ROOT" "$LAB/state" "$ID"
}
echo "== fm-pr-check.sh $ID $URL (trace $TRACE)"
"$ROOT/bin/fm-pr-check.sh" "$ID" "$URL"; echo "rc=$?"
echo "-- meta after PR registration:"; cat "$LAB/state/$ID.meta"
echo "-- watcher verdict: $(verdict)"
echo "== fm-control.sh relaunch $ID (pane command: $(T display-message -p -t "lab:fm-$ID" '#{pane_current_command}'))"
SOCK=$(T display-message -p "#{socket_path}"); echo "socket=$SOCK"; TMUX="$SOCK,1,0" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "continuing after the PR" 2>&1; echo "rc=$?"
echo "-- meta after relaunch:"; cat "$LAB/state/$ID.meta"
echo "-- watcher verdict after relaunch: $(verdict)"
if [ "${FM_LIVE_TWICE:-}" = 1 ]; then
  sleep 12
  echo "== second fm-control.sh relaunch $ID"
  TMUX="$SOCK,1,0" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "second relaunch" 2>&1 | grep -E "relaunched|error"; echo "rc=${PIPESTATUS[0]}"
  echo "-- meta after second relaunch:"; cat "$LAB/state/$ID.meta"
  echo "-- watcher verdict after second relaunch: $(verdict)"
fi
echo "-- pane after relaunch:"; T capture-pane -p -t "lab:fm-$ID" | grep -v '^\s*$' | tail -8
