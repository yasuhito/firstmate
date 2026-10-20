#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh + real Treehouse + real tmux (private lab
# socket) against disposable lab homes. Usage: driver.sh <repo-worktree>
set -u
ROOT=$1
EVID=$(cd "$(dirname "$0")" && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
SMHOME="$LAB/sm-home"
FAKEHOME="$LAB/userhome"   # HOME for the spawned panes: Treehouse default root lives here, not in ~
mkdir -p "$FAKEHOME" "$LAB/tmux"
"$ROOT/bin/fm-lab-home.sh" create "$LAB/primary" >/dev/null || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$SMHOME" >/dev/null || exit 1
printf 'sm-qa\n' > "$SMHOME/.fm-secondmate-home"
export TMUX_TMPDIR="$LAB/tmux"
cleanup() {
  for r in "$LAB/primary/state/treehouse" "$SMHOME/state/treehouse" "$FAKEHOME/.treehouse"; do :; done
  tmux kill-server 2>/dev/null
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
}
trap cleanup EXIT

say() { printf '\n=== %s ===\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }

# One origin, three clones: primary home's projects/qa2, secondmate home's
# projects/qa2, and an "operator checkout" elsewhere - same dir name + origin.
SEED="$LAB/seed"; mkdir -p "$SEED"
git -C "$SEED" init -q -b main
printf '# qa2\n' > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" -c user.name=t -c user.email=t@t commit -qm initial
git clone -q --bare "$SEED" "$LAB/qa2.git"
ORIGIN="file://$LAB/qa2.git"
git clone -q "$ORIGIN" "$LAB/primary/projects/qa2"
git clone -q "$ORIGIN" "$SMHOME/projects/qa2"
mkdir -p "$LAB/operator"; git clone -q "$ORIGIN" "$LAB/operator/qa2"

spawn() { # <home> <id> <proj> [args...]
  local home=$1 id=$2 proj=$3; shift 3
  local bin=${SPAWN_ROOT:-$ROOT}
  mkdir -p "$home/data/$id"; printf "# Task\n## Captain's intent\nLive pool-root check for %s.\n\n## Firstmate spec\nExercise the spawn behavior under test.\n" "$id" > "$home/data/$id/brief.md"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TREEHOUSE_ROOT \
      HOME="$FAKEHOME" SHELL=/bin/bash FM_SPAWN_NO_GUARD=1 FM_HOME="$home" \
      "$bin/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo launched-$id; exec bash'" \
      --backend tmux "$@"
}
common() { (cd "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P); }

say "S1 primary home spawn allocates from <primary>/state/treehouse"
spawn "$LAB/primary" p1 "$LAB/primary/projects/qa2" --mode local-only --yolo off; echo "exit=$?"
WT=$(sed -n 's/^worktree=//p' "$LAB/primary/state/p1.meta"); echo "recorded worktree=$WT"
echo "worktree common dir=$(common "$WT")"; echo "project common dir=$(common "$LAB/primary/projects/qa2")"
echo "pool roots under primary state:"; ls "$LAB/primary/state/treehouse"
echo "default root (\$HOME/.treehouse) contents (pools would appear as <name>-<hash>/):"; ls -A "$FAKEHOME/.treehouse" 2>/dev/null || echo "<absent>"
tmux list-windows -a -F '#{session_name}:#{window_name} cwd=#{pane_current_path}'

say "S2 secondmate home spawn allocates from <sm-home>/state/treehouse"
spawn "$SMHOME" s1 "$SMHOME/projects/qa2" --mode local-only --yolo off; echo "exit=$?"
WT=$(sed -n 's/^worktree=//p' "$SMHOME/state/s1.meta"); echo "recorded worktree=$WT"
echo "worktree common dir=$(common "$WT")"; echo "project common dir=$(common "$SMHOME/projects/qa2")"
echo "pool roots under sm state:"; ls "$SMHOME/state/treehouse"
echo "default root contents:"; ls -A "$FAKEHOME/.treehouse" 2>/dev/null || echo "<absent>"

say "S3 adversarial: a free slot created by ANOTHER clone sits in the secondmate's own pool root"
# The operator checkout (same dir name + origin) allocates and returns a slot
# under the secondmate's root, leaving a free foreign slot in pool qa2-<hash>.
SMROOT="$SMHOME/state/treehouse"
( cd "$LAB/operator/qa2" && HOME="$FAKEHOME" run treehouse --root "$SMROOT" status ) || true
# Return the secondmate's own s1 slot is in-use; create another foreign one:
FOREIGN=$( cd "$LAB/operator/qa2" && HOME="$FAKEHOME" treehouse --root "$SMROOT" get --lease 2>/dev/null )
echo "$FOREIGN"
ls -d "$SMROOT"/.treehouse/*/*/qa2
for d in "$SMROOT"/.treehouse/*/*/qa2; do printf '%s common=%s\n' "$d" "$(common "$d")"; done
FS=$(for d in "$SMROOT"/.treehouse/*/*/qa2; do [ "$(common "$d")" = "$(common "$LAB/operator/qa2")" ] && echo "$d"; done | head -1)
echo "foreign slot=$FS"
[ -n "$FS" ] && ( cd "$LAB/operator/qa2" && HOME="$FAKEHOME" treehouse --root "$SMROOT" return --force "$FS" ) && echo "foreign slot returned to pool (free)"
( cd "$SMHOME/projects/qa2" && HOME="$FAKEHOME" treehouse --root "$SMROOT" status ) || true
FHEAD=$(git -C "$FS" rev-parse HEAD 2>/dev/null); FREFLOG=$(git -C "$FS" reflog 2>/dev/null | wc -l)
FFETCH="$(git -C "$FS" rev-parse --absolute-git-dir 2>/dev/null)/FETCH_HEAD"; FFETCH_BEFORE=$([ -e "$FFETCH" ] && stat -c %Y "$FFETCH" || echo none)
# Advance origin so a fetch/reset would visibly move the slot.
git -C "$SEED" -c user.name=t -c user.email=t@t commit -q --allow-empty -m advance
git -C "$SEED" push -q "$LAB/qa2.git" main
spawn "$SMHOME" s2 "$SMHOME/projects/qa2" --scout 2>&1 | tail -6; echo "exit=${PIPESTATUS[0]}"
echo "s2 meta exists? $([ -e "$SMHOME/state/s2.meta" ] && echo yes || echo no)"
echo "foreign slot HEAD before=$FHEAD after=$(git -C "$FS" rev-parse HEAD)"
echo "foreign slot reflog lines before=$FREFLOG after=$(git -C "$FS" reflog | wc -l)"
echo "foreign slot FETCH_HEAD mtime before=$FFETCH_BEFORE after=$([ -e "$FFETCH" ] && stat -c %Y "$FFETCH" || echo none)"
echo "foreign slot .fm-slot-owner: $(cat "$(dirname "$FS")/.fm-slot-owner" 2>/dev/null || echo '<none>')"
echo "foreign slot still exists? $([ -d "$FS" ] && echo yes || echo no)"

say "S4 legacy: task spawned by the PRE-change fm-spawn (default root) is torn down by the new code and returned by its recorded path"
BASE="$LAB/base"; mkdir -p "$BASE"; git -C "$ROOT" archive 1aa2a21ec35e2d0644ac836b7b5d3cb36669ef33 | tar -x -C "$BASE"
SPAWN_ROOT="$BASE" spawn "$LAB/primary" legacy1 "$LAB/primary/projects/qa2" --mode local-only --yolo off; echo "old-spawn exit=$?"
LEG=$(sed -n 's/^worktree=//p' "$LAB/primary/state/legacy1.meta"); echo "legacy recorded worktree=$LEG"
case "$LEG" in "$FAKEHOME/.treehouse/"*) echo "-> lives under the OLD default root (\$HOME/.treehouse)";; *) echo "-> NOT under default root";; esac
echo "default-root status before teardown:"; ( cd "$LAB/primary/projects/qa2" && HOME="$FAKEHOME" treehouse status ) 2>&1 | grep -v -e 'new version' -e 'treehouse update' -e '^$'
# Land the task's work on local main so local-only teardown is allowed.
( cd "$LEG" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "legacy work" )
git -C "$LAB/primary/projects/qa2" merge -q --ff-only "$(git -C "$LEG" rev-parse HEAD)" && echo "legacy work landed on local main"
env -u NO_MISTAKES_GATE -u TMUX HOME="$FAKEHOME" FM_HOME="$LAB/primary" "$ROOT/bin/fm-teardown.sh" legacy1 2>&1 | tail -8; echo "teardown exit=${PIPESTATUS[0]}"
echo "legacy1.meta remains? $([ -e "$LAB/primary/state/legacy1.meta" ] && echo yes || echo no)"
echo "default-root status after teardown:"; ( cd "$LAB/primary/projects/qa2" && HOME="$FAKEHOME" treehouse status ) 2>&1 | grep -v -e 'new version' -e 'treehouse update' -e '^$'
echo "slot owner file after: $(cat "$(dirname "$LEG")/.fm-slot-owner" 2>/dev/null || echo '<none>')"
echo "primary own-root status (p1 still in use):"; ( cd "$LAB/primary/projects/qa2" && HOME="$FAKEHOME" treehouse --root "$LAB/primary/state/treehouse" status ) 2>&1 | grep -v -e 'new version' -e 'treehouse update' -e '^$'

say "cleanup: return live slots"
for h in "$LAB/primary" "$SMHOME"; do for m in "$h"/state/*.meta; do [ -e "$m" ] || continue
  w=$(sed -n 's/^worktree=//p' "$m"); [ -d "$w" ] && HOME="$FAKEHOME" treehouse return --force "$w" >/dev/null 2>&1; done; done
echo done
