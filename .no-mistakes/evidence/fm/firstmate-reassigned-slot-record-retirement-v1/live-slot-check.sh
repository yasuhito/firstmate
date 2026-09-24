#!/usr/bin/env bash
set -u
ROOT=/home/yasuhito/.no-mistakes/worktrees/38526edaf053/01M396JYGJ7H48NY4XYTA4A3PB
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$($LAB name slot-retire) || exit 1
export HERDR_SESSION="$SESSION"
TMP=$(mktemp -d "$ROOT/.slot-live.XXXXXX")
WT=()
declare -A PANES
cleanup() {
  local wt
  for wt in "${WT[@]}"; do [ -z "$wt" ] || treehouse return --force "$wt" >/dev/null 2>&1 || true; done
  "$LAB" teardown "$SESSION"
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
"$LAB" provision "$SESSION" || fail 'lab provision'
mkdir -p "$TMP/home/state" "$TMP/home/data" "$TMP/home/config" "$TMP/project"
printf 'off\n' > "$TMP/home/config/herdr-presentation-spaces"
printf 'manual\n' > "$TMP/home/config/backlog-backend"
git -C "$TMP/project" init -q
printf 'scratch\n' > "$TMP/project/README.md"
git -C "$TMP/project" add README.md
git -C "$TMP/project" -c user.name=test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$TMP/project" "$TMP/origin.git"
git -C "$TMP/project" remote add origin "file://$TMP/origin.git"
for id in first-task second-task owner-task; do
  mkdir -p "$TMP/home/data/$id"
  printf '# Task\n## Captain\x27s intent\nExercise isolated teardown.\n## Firstmate spec\nVerify record safety.\n' > "$TMP/home/data/$id/brief.md"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$TMP/project" "sh -c 'echo $id-ready; sleep 120'" \
    --mode no-mistakes --yolo off --backend herdr > "$TMP/$id.spawn.out" 2> "$TMP/$id.spawn.err" \
    || fail "spawn $id: $(cat "$TMP/$id.spawn.err")"
  wt=$(sed -n 's/^worktree=//p' "$TMP/home/state/$id.meta")
  WT+=("$wt")
  PANES[$id]=$(sed -n 's/^herdr_pane_id=//p' "$TMP/home/state/$id.meta")
  printf 'SPAWN %s window=%s worktree=%s\n' "$id" "$(sed -n 's/^window=//p' "$TMP/home/state/$id.meta")" "$wt"
done
OWNER_WT=${WT[2]}
CLAIM=$(dirname "$(readlink -f "$OWNER_WT")")/.fm-slot-owner
printf 'owner claim: %s\n' "$(cat "$CLAIM")"
[ "$(sed -n 's/^task=//p' "$CLAIM")" = owner-task ] || fail 'owner claim missing'
printf 'owner copy preserved\n' > "$OWNER_WT/live-sentinel"
for id in first-task second-task; do
  sed -i "s|^worktree=.*|worktree=$OWNER_WT|" "$TMP/home/state/$id.meta"
done
run_td() { FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" "$1" > "$TMP/$1.td.out" 2> "$TMP/$1.td.err"; }
if run_td owner-task; then fail 'owner unexpectedly returned duplicate slot'; fi
[ -f "$TMP/home/state/owner-task.meta" ] || fail 'owner record lost on refusal'
[ -f "$OWNER_WT/live-sentinel" ] || fail 'owner copy altered on refusal'
grep -q 'also task' "$TMP/owner-task.td.err" || fail 'owner did not refuse duplicate records'
printf 'OWNER REFUSED: %s\n' "$(grep -m1 'REFUSED:' "$TMP/owner-task.td.err")"
for id in first-task second-task; do
  run_td "$id" || fail "retire $id: $(cat "$TMP/$id.td.err")"
  [ ! -f "$TMP/home/state/$id.meta" ] || fail "$id record remains"
  if "$LAB" run "$SESSION" pane get "${PANES[$id]}" >/dev/null 2>&1; then fail "$id pane remains"; fi
  [ -f "$TMP/home/state/owner-task.meta" ] || fail 'owner record lost'
  [ -f "$OWNER_WT/live-sentinel" ] || fail 'owner copy altered'
  [ "$(sed -n 's/^task=//p' "$CLAIM")" = owner-task ] || fail 'owner claim changed'
  pane=$(sed -n 's/^herdr_pane_id=//p' "$TMP/home/state/owner-task.meta")
  "$LAB" run "$SESSION" pane get "$pane" >/dev/null || fail 'owner pane closed'
  grep -q 'reassigned' "$TMP/$id.td.err" || fail 'reassignment warning absent'
  printf 'RETIRED %s pane %s; owner pane %s and copy intact; %s\n' "$id" "${PANES[$id]}" "$pane" "$(grep -m1 'reassigned' "$TMP/$id.td.err")"
done
if run_td owner-task; then fail 'owner unexpectedly returned dirty copy'; fi
[ -f "$OWNER_WT/live-sentinel" ] || fail 'dirty owner copy lost'
grep -q 'REFUSED:' "$TMP/owner-task.td.err" || fail 'dirty owner reason absent'
printf 'DIRTY OWNER REFUSED: %s\n' "$(grep -m1 'REFUSED:' "$TMP/owner-task.td.err")"
printf 'task=\ntask=owner-task\nhome=%s\n' "$TMP/home" > "$CLAIM"
if run_td owner-task; then fail 'malformed claim accepted'; fi
[ -f "$OWNER_WT/live-sentinel" ] || fail 'malformed claim changed copy'
grep -q 'claim that cannot be read' "$TMP/owner-task.td.err" || fail 'malformed claim refusal absent'
printf 'MALFORMED CLAIM REFUSED: %s\n' "$(grep -m1 'REFUSED:' "$TMP/owner-task.td.err")"
printf 'task=owner-task\nhome=\nhome=%s\n' "$TMP/home" > "$CLAIM"
if run_td owner-task; then fail 'malformed home claim accepted'; fi
[ -f "$OWNER_WT/live-sentinel" ] || fail 'malformed home claim changed copy'
grep -q 'claim that cannot be read' "$TMP/owner-task.td.err" || fail 'malformed home claim refusal absent'
printf 'MALFORMED HOME CLAIM REFUSED: %s\n' "$(grep -m1 'REFUSED:' "$TMP/owner-task.td.err")"
printf 'task=owner-task\nhome=%s\n' "$TMP/home" > "$CLAIM"
rm "$OWNER_WT/live-sentinel"
run_td owner-task || fail "owner final teardown: $(cat "$TMP/owner-task.td.err")"
[ ! -f "$TMP/home/state/owner-task.meta" ] || fail 'owner record remains'
[ ! -e "$CLAIM" ] || fail 'owner claim remains'
printf 'OWNER RETIRED after exclusive clean slot\n'
