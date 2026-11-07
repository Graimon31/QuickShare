#!/usr/bin/env bash
# Runs the remote peer check in the direction "a GitHub runner sends, this Mac
# receives" (see CI_PEER.md).
#
# What it does, in order:
#
#   1. picks a ten-digit code, a seed that stands for the file, and a name for
#      this Mac, at random;
#   2. makes a git worktree in a temporary folder, on a new branch
#      ci-peer/<name> cut from the commit you are on, and commits
#      ci-peer/peer.json there (direction "to-mac", the code, the name, the size,
#      the seed);
#   3. pushes that branch, which starts .github/workflows/ci_peer.yml: the runner
#      builds (ten to fifteen minutes), then offers the file under the code to
#      the one receiver that has the name;
#   4. starts the receiver here at once, and it searches for the code again and
#      again for up to forty minutes, until the runner's sender is up. It works
#      the expected SHA-256 out from the seed and fails on any difference;
#   5. prints how it ended, then rebuilds the macOS app (an integration run
#      replaces the app bundle with its own).
#
# The commit you are on is what the runner builds, and the working tree is what
# this Mac runs: they have to be the same code, so the script refuses to go on
# with uncommitted changes under quickshare/ or .github/ (--allow-dirty goes on
# anyway).
#
#   --dry-run          do steps 1 and 2 and stop: nothing is pushed and nothing
#                      is started. Shows what would be pushed, then removes the
#                      worktree and the branch. Does not touch the network.
#   --bytes N          size of the file (default 52428800 = 50 MiB; at most 2 GiB)
#   --force-relay      relay candidates only, on both ends
#   --find-minutes M   how long this Mac searches (default 40)
#   --remote NAME      the git remote to push to (default origin)
#   --no-rebuild       skip the final `flutter build macos --debug`
#   --allow-dirty      run even though the working tree differs from the commit
#
# The code, the seed and the name go to a public repository, and none of them is
# a secret: the sender accepts only the one name, once, and the file is bytes
# that are worth nothing. Delete the branch afterwards (the command is printed).
#
# Leave the Mac awake (caffeinate does that), the app window it opens visible,
# and the VPN on.
set -euo pipefail

DRY_RUN=0
BYTES=52428800
FORCE_RELAY=false
FIND_MINUTES=40
REMOTE=origin
REBUILD=1
ALLOW_DIRTY=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "ci_peer_to_mac: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --bytes) [ $# -ge 2 ] || die "--bytes needs a number"; BYTES=$2; shift ;;
    --force-relay) FORCE_RELAY=true ;;
    --find-minutes) [ $# -ge 2 ] || die "--find-minutes needs a number"; FIND_MINUTES=$2; shift ;;
    --remote) [ $# -ge 2 ] || die "--remote needs a name"; REMOTE=$2; shift ;;
    --no-rebuild) REBUILD=0 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ "$BYTES" =~ ^[1-9][0-9]{0,9}$ ]] && [ "$BYTES" -le 2147483648 ] \
  || die "--bytes must be a whole number from 1 to 2147483648 (2 GiB)"
[[ "$FIND_MINUTES" =~ ^[1-9][0-9]{0,2}$ ]] || die "--find-minutes must be a whole number of minutes"
[[ "$REMOTE" =~ ^[A-Za-z0-9._-]+$ ]] || die "--remote must be the name of a git remote"

for tool in git openssl; do
  command -v "$tool" > /dev/null || die "$tool is needed and was not found"
done
if [ "$DRY_RUN" -eq 0 ]; then
  for tool in flutter caffeinate; do
    command -v "$tool" > /dev/null || die "$tool is needed and was not found"
  done
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
app_dir=$(dirname "$script_dir")
repo_root=$(git -C "$app_dir" rev-parse --show-toplevel)
[ -f "$app_dir/integration_test/ci_peer_receiver.dart" ] \
  || die "this is not the DirectDrop checkout: $app_dir/integration_test/ci_peer_receiver.dart is missing"

base_branch=$(git -C "$repo_root" symbolic-ref --short -q HEAD) \
  || die "HEAD is detached: switch to the branch the runner should build"
base_commit=$(git -C "$repo_root" rev-parse --short HEAD)
case "$base_branch" in ci-peer/*) die "you are on $base_branch: switch to the branch the runner should build" ;; esac

if [ "$ALLOW_DIRTY" -eq 0 ]; then
  changed=$(git -C "$repo_root" status --porcelain --untracked-files=all -- quickshare .github)
  if [ -n "$changed" ]; then
    echo "$changed" | head -n 20 >&2
    msg="the working tree differs from $base_branch ($base_commit) under quickshare/ or .github/ (listed above). The runner builds the commit and this Mac runs the files: commit first, or pass --allow-dirty"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "ci_peer_to_mac: WARNING, a real run would stop here: $msg" >&2
    else
      die "$msg"
    fi
  fi
fi

# ── 1. What this check is about ────────────────────────────────────────────
suffix=$(openssl rand -hex 3)
name="mac-$suffix"
branch="ci-peer/$name"
seed=$(openssl rand -hex 32)
# Ten digits, from 56 random bits (the remainder is biased by less than 1e-7).
code=$(printf '%010d' $(( 0x$(openssl rand -hex 7) % 10000000000 )))
[[ "$code" =~ ^[0-9]{10}$ && "$seed" =~ ^[0-9a-f]{64}$ && "$name" =~ ^[A-Za-z0-9._-]{1,40}$ ]] \
  || die "could not draw a code, a seed and a name (openssl rand failed?)"

log="${TMPDIR:-/tmp}/ci_peer_to_mac_$name.log"
work=$(mktemp -d "${TMPDIR:-/tmp}/ci-peer-to-mac.XXXXXX")
worktree="$work/worktree"
pushed=0
finished=0

cleanup() {
  local status=$?
  set +e
  if [ "$pushed" -eq 1 ] && [ "$finished" -eq 0 ]; then
    echo "ci_peer_to_mac: stopped after the push: the branch is still on $REMOTE. Delete it with: git push $REMOTE --delete $branch" >&2
  fi
  if [ -d "$worktree" ]; then
    git -C "$repo_root" worktree remove --force "$worktree" > /dev/null 2>&1
  fi
  git -C "$repo_root" worktree prune > /dev/null 2>&1
  # The local branch was only ever the carrier of one commit; the remote one,
  # if there is one, is not touched.
  git -C "$repo_root" branch -D "$branch" > /dev/null 2>&1
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'echo; echo "ci_peer_to_mac: interrupted" >&2; exit 130' INT TERM

echo "== ci-peer to-mac: $name"
echo "   base:    $base_branch ($base_commit)"
echo "   branch:  $branch"
echo "   file:    $BYTES bytes, from a random seed"
echo "   relay:   $([ "$FORCE_RELAY" = true ] && echo 'relay candidates only' || echo 'whatever ICE finds')"

# ── Pre-flight: the programs this Mac is about to run have to compile ──────
# Cheap, and a run that fails to start after the push has wasted the runner's
# ten to fifteen minutes.
if command -v dart > /dev/null; then
  echo "== analysing the receiver and the sender"
  (cd "$app_dir" && dart analyze integration_test/ci_peer_receiver.dart integration_test/ci_peer_sender.dart) \
    || die "the receiver or the sender does not analyse cleanly: nothing was pushed"
fi

# ── 2. The branch with peer.json ────────────────────────────────────────────
git -C "$repo_root" worktree add -q -b "$branch" "$worktree" HEAD
mkdir -p "$worktree/ci-peer"
printf '{\n  "direction": "to-mac",\n  "code": "%s",\n  "name": "%s",\n  "bytes": %s,\n  "seed": "%s",\n  "forceRelay": %s\n}\n' \
  "$code" "$name" "$BYTES" "$seed" "$FORCE_RELAY" > "$worktree/ci-peer/peer.json"
git -C "$worktree" add ci-peer/peer.json
git -C "$worktree" commit -q -m "ci-peer: to-mac $name"
commit=$(git -C "$worktree" rev-parse --short HEAD)

echo "== ci-peer/peer.json in $commit (public once pushed):"
sed 's/^/   /' "$worktree/ci-peer/peer.json"
echo "   (the commit changes only that file: $(git -C "$worktree" diff --stat HEAD~1 HEAD | tail -n 1 | sed 's/^ *//'))"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "== dry run: nothing pushed, nothing started. A real run would now:"
  echo "   git push $REMOTE $branch"
  echo "   cd $app_dir && caffeinate -dimsu flutter test integration_test/ci_peer_receiver.dart -d macos --reporter=expanded \\"
  echo "     --dart-define=CI_PEER_CODE=<the code> --dart-define=CI_PEER_NAME=$name --dart-define=CI_PEER_BYTES=$BYTES \\"
  echo "     --dart-define=CI_PEER_SEED=<the seed> --dart-define=CI_PEER_FIND_MINUTES=$FIND_MINUTES \\"
  echo "     --dart-define=QUICKSHARE_FORCE_RELAY=$FORCE_RELAY"
  echo "   and, afterwards, flutter build macos --debug."
  echo "   The worktree and the branch are removed now."
  exit 0
fi

# ── 3. Push: the runner starts ──────────────────────────────────────────────
echo "== pushing $branch to $REMOTE"
git -C "$worktree" push --quiet "$REMOTE" "refs/heads/$branch:refs/heads/$branch"
pushed=1
echo "   pushed at $(date '+%H:%M:%S'); the runner now builds, ten to fifteen minutes"

url=$(git -C "$repo_root" remote get-url "$REMOTE" 2> /dev/null || true)
web=$(printf '%s' "$url" | sed -E 's#^git@([^:]+):#https://\1/#; s#^ssh://git@([^/]+)/#https://\1/#; s#\.git$##')
case "$web" in https://*) echo "   Actions: $web/actions?query=branch%3A$(printf '%s' "$branch" | sed 's#/#%2F#g')" ;; esac

# ── 4. Receive here, at once ────────────────────────────────────────────────
echo "== receiving here: searching for the code for up to $FIND_MINUTES minutes"
echo "   log: $log"
set +e
(
  cd "$app_dir"
  caffeinate -dimsu flutter test integration_test/ci_peer_receiver.dart -d macos \
    --reporter=expanded \
    --dart-define=CI_PEER_CODE="$code" \
    --dart-define=CI_PEER_NAME="$name" \
    --dart-define=CI_PEER_BYTES="$BYTES" \
    --dart-define=CI_PEER_SEED="$seed" \
    --dart-define=CI_PEER_FIND_MINUTES="$FIND_MINUTES" \
    --dart-define=QUICKSHARE_FORCE_RELAY="$FORCE_RELAY" \
    2>&1 | tee "$log"
  exit "${PIPESTATUS[0]}"
)
received=$?
set -e

# ── 5. The result, and the app put back ─────────────────────────────────────
echo
echo "== result of the receiver on this Mac"
if grep -q 'CI_PEER ---- receiver result ----' "$log" 2> /dev/null; then
  sed -n '/CI_PEER ---- receiver result ----/,/CI_PEER_SUMMARY_WRITTEN/p' "$log" \
    | grep -v 'CI_PEER_SUMMARY_WRITTEN' | sed 's/^CI_PEER //'
else
  echo "   the receiver never reported: it did not build or start (see $log)"
fi
if [ "$received" -eq 0 ]; then
  echo "== PASSED: the file arrived whole from the runner"
else
  echo "== FAILED (exit $received); the runner's side is on the Actions page"
fi

if [ "$REBUILD" -eq 1 ]; then
  echo "== rebuilding the macOS app (the integration run replaced its bundle)"
  if (cd "$app_dir" && flutter build macos --debug > "$log.build" 2>&1); then
    echo "   flutter build macos --debug: done"
  else
    echo "   flutter build macos --debug FAILED: see $log.build" >&2
  fi
else
  echo "== not rebuilt: run \`flutter build macos --debug\` in $app_dir before opening the app"
fi

finished=1
echo "== delete the branch when you have looked at the run:"
echo "   git push $REMOTE --delete $branch"
exit "$received"
