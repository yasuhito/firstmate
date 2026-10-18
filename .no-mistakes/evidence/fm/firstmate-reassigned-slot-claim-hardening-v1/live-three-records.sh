#!/usr/bin/env bash
# Live drive of bin/fm-teardown.sh against a disposable lab home and a real
# private tmux server: three task records naming one pool slot, claim names the
# last taker. Usage: live-three-records.sh <repo-root> <claim-variant>
set -u
ROOT=$1; VARIANT=${2:-owner}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/pool/1"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
RLOG="$LAB/treehouse.log"; : > "$RLOG"
cat > "$LAB/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse' >> "$RLOG"; printf ' <%s>' "\$@" >> "$RLOG"; printf '\n' >> "$RLOG"
SH
chmod +x "$LAB/fakebin/treehouse"
PROJ="$LAB/projects/demo"; git init -q "$PROJ"
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm init
git -C "$PROJ" worktree add -q --detach "$LAB/pool/1/project"
SLOT="$LAB/pool/1/project"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$LAB/pool/treehouse-state.json"
: > "$SLOT/sentinel"
tmux new-session -d -s firstmate -n fm-first-task -c "$SLOT" "sleep 600"
tmux new-window -t firstmate -n fm-second-task -c "$SLOT" "sleep 600"
tmux new-window -t firstmate -n fm-owner-task -c "$SLOT" "sleep 600"
for id in first-task second-task owner-task; do
  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\n' \
    "$id" "$id" "$SLOT" "$PROJ" > "$LAB/state/$id.meta"
done
case "$VARIANT" in
  owner) printf 'task=owner-task\nhome=%s\n' "$LAB" ;;
  conflicting) printf 'task=first-task\ntask=owner-task\nhome=%s\n' "$LAB" ;;
  empty-task-first) printf 'task=\ntask=owner-task\nhome=%s\n' "$LAB" ;;
  conflicting-home) printf 'task=owner-task\nhome=%s\nhome=/elsewhere\n' "$LAB" ;;
  repeated-same) printf 'task=owner-task\ntask=owner-task\nhome=%s\nhome=%s\n' "$LAB" "$LAB" ;;
esac > "$LAB/pool/1/.fm-slot-owner"
show() {
  echo "--- state: records=[$(cd "$LAB/state" && ls *.meta 2>/dev/null | tr '\n' ' ')] windows=[$(tmux list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')] sentinel=$([ -e "$SLOT/sentinel" ] && echo present || echo GONE) claim=[$(tr '\n' ' ' < "$LAB/pool/1/.fm-slot-owner" 2>/dev/null || echo ABSENT)] treehouse-calls=[$(cat "$RLOG" | tr '\n' ' ')]"
}
td() {
  echo; echo "\$ fm-teardown.sh $*"
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" "$@" 2>&1 | sed 's/^/  | /'
  echo "  exit=${PIPESTATUS[0]}"; show
}
echo "=== variant: $VARIANT (lab $LAB) ==="; show
case "$VARIANT" in
  owner)
    td owner-task
    td first-task
    td second-task
    td owner-task --force ;;
  repeated-same)
    td first-task
    td second-task
    td owner-task ;;
  *)
    td first-task
    td owner-task
    td owner-task --force ;;
esac
tmux kill-server 2>/dev/null
"$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
rm -rf "$LAB"
echo "=== lab removed: $([ -e "$LAB" ] && echo NO || echo yes) ==="
