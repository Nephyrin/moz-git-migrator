#!/bin/bash

set -e

##
## Config
##

#FIXME warn on remote-not-found that you can edit these
# The new SHAs
REMOTE_NEW=https://github.com/mozilla/gecko-dev
# The old SHAs
REMOTE_OLD=https://github.com/mozilla/mozilla-central
# The projects shas we're adding
REMOTE_PROJECTS=https://github.com/mozilla/gecko-projects

# If set, try to strip the protocol from remotes to compare them, e.g.
# foo@github.com:mozilla/bob -> github.com/mozilla/bob, so we match the various
# ways of pulling from github. If you change this to use a specific or
# non-github remote, set to 0
REMOTE_COMPARE_NORMALIZE=1

# The root commits for the trees we're aware of. FIXME needed with syncbase?
ROOT_NEW=3b56a9af51519d2e77e05efa672a13e6be2e9ebc
ROOT_OLD=781c48087175615674b38b31fcc0aae17f0651b6
ROOT_PROJECTS=fbf6b2c8fb285414ff412f2088b368efbf3172ed

# These are two commits that match up from the two sets of shas, after which all
# subsequent shas align when using |git rev-list --ancestry-path|. These are the
# first Hg commits after CVS -- Before this, the history diverges due to
# differing CVS import methods before this.
# If you have a branch based on a CVS commit, god help you.
SYNCBASE_NEW=f6626f2142251f2b410205eed77278c5ae01a567
SYNCBASE_OLD=00544122728fe5fc2db502823b1068102d1c3acc

# This is a tag that exists in both remotes, so we can easily check if you need
# to run git fetch --tags <newremote>. Unset TAGCHECK to disable. #FIXME
TAGCHECK=RELEASE_BASE_20110811
TAGCHECK_NEW=451a52c38d00be066fcc8d028ecb49f14757b08a

# Format used to narrow search for matching commits
COMMIT_MATCH_FORMAT="%T%ct%at"

##
## Util
##

sh_c()
{
  [ -n "$usecolor" ] || return
  local c="$1"
  local b="$2"
  [ ! -z "$c" ] || c=0
  [ ! -z "$b" ] || [ $c -eq 0 ] || b=0
  [ -z "$b" ] || b="$b;"
  echo -n -e "\033[$b${c}m"
}

# Print things
heading() { echo >&2 "$(sh_c 34 1)##$(sh_c) $(sh_c 36 2)$*$(sh_c)"; }
exit_needswork() {
  pad
  heading Result
  action "Address the issues above and then RERUN THIS SCRIPT to ensure" \
         "your repository is properly migrated."
  pad
  exit 1
}
pad() { echo >&2 ""; }
# indent 2
action() {
  action_shown=1
  echo >&2 "  $(sh_c 33 1)>>$(sh_c) $*";
}
# indent 2
allgood() { echo >&2 "  $(sh_c 32 1)>>$(sh_c) $*"; }
# indent 4 (shown under actions)
showcmd() { echo >&2 "     $(sh_c 33 1)\$$(sh_c) $(sh_c 33 2)$*$(sh_c)"; }
stat() { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
warn() { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
err() { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }
vstat() {
  [ -z "$verbose" ] || echo >&2 "$(sh_c 30 1)--$(sh_c 37 0) $*$(sh_c)"
}
die() { err "$@" && exit 1; }
# Shows commands we're running in verbose mode
cmd() {
  [ -z "$verbose" ] || echo >&2 "$(sh_c 30 1) +$(sh_c 37 0) $*$(sh_c)"
  "$@"
}

usage() {
  echo >&2 "./moz-git-migrator.sh [-n] [-v] git-directory"
  echo >&2 "  -n Disable pretty colors"
  echo >&2 "  -v Be verbose"
  echo >&2 ""
  echo >&2 "This script will analyze the target mozilla-git directory and"
  echo >&2 "generate an annotated list of commands to migrate it to the"
  echo >&2 "new/official git mirror with differing commit SHAs."
  echo >&2 ""
  echo >&2 "This script will NOT run any command on your repository by itself."
}

##
## Parse options
##

while getopts :nv OPT; do
  case "$OPT" in
    v) # verbose
      if [ -z "$verbose" ]; then
        verbose=1
        vstat "Verbose output enabled"
      fi
    ;;
    n) # no color
      nocolor=1
    ;;
    \?)
      err "Unknown option"
      usage
      exit 1
    ;;
    *)
      err "Error parsing options"
      usage
      exit 1
    ;;
  esac
done

if [[ -t 1 && -z "$nocolor" ]]; then
  vstat "Enabling color output"
  usecolor=1
fi

if [[ "$OPTIND" -ne $# ]]; then
  usage
  exit 1
fi

eval gitdir=\"\$$OPTIND\"

##
## Git/util functions
##

# See comment for REMOTE_COMPARE_NORMALIZE above
remote_normalize()
{
  local url="$1"
  if [ -n "$REMOTE_COMPARE_NORMALIZE" ]; then
    if [ "$url" != "${url#https://}" ]; then
      url="${url#https://}"
    elif [ "$url" != "${url#http://}" ]; then
      url="${url#http://}"
    elif [ "$url" != "${url#git://}" ]; then
      url="${url#git://}"
    elif [ "$url" != "${url#*@}" ]; then
      url="${url#*@}"
      url="${url/://}"
    fi
    url="${url%%/}"
    url="${url%.git}"
  fi
  echo "$url"
}

# git-branch is a porcelain command, but we really want its --contains
# optimization
parse-git-branch() {
  local IFS;
  local output;
  local item;
  output="$(cmd $@)"
  IFS=$'\n';
  output=($output);
  for item in "${output[@]}"; do
    item="${item#??}"
    # Skip branches with pointer annotations
    [ "$item" != "${item% *}" ] || echo "${item%% *}"
  done
}

# Given a ref, returns ($oldbase $newbase) suitable for e.g.
#   $ git rebase $oldbase --onto $newbase
# Expects refs_old and treehashes_new have been filled
find_rebase_point() {
  local branch="$1"
  local reachable_ref_old reachable_ref_new
  local reachable_path reachable_path_length
  local reachable_ref_offset=0

  local rebase_old_base="$(cmd git merge-base $branch "${refs_old[@]}")"
  vstat "Base in old SHAs for branch $branch is $rebase_old_base"

  local sig="$(git log --no-walk --format="format:$COMMIT_MATCH_FORMAT" \
                       "$rebase_old_base")"
  local candidate
  local i=0
  # treehashes is a list of pairs (treehash matchingcommit)
  while [ "$i" -lt $(( ${#treehashes_new[@]} - 1 )) ]; do
    candidate=${treehashes_new[$(($i + 1))]}
    if [ "${treehashes_new[$i]}" = "$sig" ] && \
       commits_identical $rebase_old_base $candidate; then
      echo $rebase_old_base $candidate
      return
    fi
    (( i += 2 ))
  done
}

#FIXME old head > new head syncbase length implies fetch needed

# Compare two commits from two sets of SHAs to see if they are the same
# re-written commit tree from SYNCBASE upwards
commits_identical() {
  local old="$1"
  local new="$2"
  vstat "Comparing commits $old and $new"
  [ -n "$old" ] && [ -n "$new" ] && [ -z "$(cmd git diff $old $new)" ] &&
  [ "$(cmd git log --format=format:$COMMIT_MATCH_FORMAT $SYNCBASE_OLD..$old)" \
    = \
    "$(cmd git log --format=format:$COMMIT_MATCH_FORMAT $SYNCBASE_NEW..$new)" ]
}

##
## Sanity checks
##

if [ ! -d "$gitdir/.git" ]; then
  die "\"$gitdir\" does not appear to be a git repository"
fi

cd "$gitdir"

# Bail early if the old SHAs aren't present
if ! cmd git show $ROOT_OLD &>/dev/null; then
  heading Result
  allgood "This repository does not contain the old SHAs, no action necessary"
  pad
  exit 0
fi

##
## Check & find remotes
##

normalized_new="$(remote_normalize "$REMOTE_NEW")"
normalized_old="$(remote_normalize "$REMOTE_OLD")"
normalized_projects="$(remote_normalize "$REMOTE_PROJECTS")"

# TODO better "you're all good" messages
heading Checking Remotes
remotes=($(cmd git remote))
for remote in "${remotes[@]}"; do
  # You can have a unconfigured remote, if you really want to.
  url="$(cmd git config remote.$remote.url || true)"
  url="$(remote_normalize "$url")"
  vstat "Normalized url is $url"
  if [ "$url" = "$normalized_new" ]; then
    remote_new="$remote"
    stat "remote $remote -> gecko-dev (New SHAs)"
  elif [ "$url" = "$normalized_old" ]; then
    remote_old="$remote"
    stat "remote $remote -> mozilla-central (Old SHAs)"
  elif [ "$url" = "$normalized_projects" ]; then
    remote_projects="$remote"
    stat "remote $remote -> gecko-projects (New SHAs)"
  else
    stat "remote $remote is not recognized"
  fi
done

##
## See if remote needs to be added
##

remote_check_fetch() {
  local remote="$1"
  local expected_base="$2"
  # Check that this remote has a master branch, and that is the expected tree.
  local root="$(cmd git rev-list remotes/"$remote"/master -- | tail -n 1)"
  if [ -z "$root" ] || [ "$root" != "$expected_base" ]; then
    action "Remote $remote does not appear to be up to date, fetch it with:"
    showcmd "git fetch $remote"
    needs_fetch=1
  fi
}

# FIXME need step to abort if old SHAs aren't present
if [ -z "$remote_old" ]; then
  needs_remote=1
  action "You don't currently have the old mozilla repository as a remote."
  action "The script needs this to generate rebase commands for your local"
  action "branches, temporarily add the old remote with:"
  showcmd "git remote add mozilla-old $REMOTE_OLD"
else
  remote_check_fetch "$remote_old" "$ROOT_OLD"
fi

if [ -z "$remote_new" ]; then
  needs_remote=1
  action "You don't currently have the new gecko-dev repo configured as a"
  action "remote. Add the new remote with:"
  showcmd "git remote add gecko-dev $REMOTE_NEW"
  showcmd "git fetch gecko-dev"
else
  remote_check_fetch "$remote_new" "$ROOT_NEW"
fi

if [ -z "$remote_projects" ]; then
  needs_remote=1
  action "You don't currently have the new gecko-projects repo configured as a"
  action "remote. Add the new remote with:"
  showcmd "git remote add gecko-projects $REMOTE_PROJECTS"
  showcmd "git fetch gecko-projects"
else
  remote_check_fetch "$remote_projects" "$ROOT_PROJECTS"
fi

## Exit if any remotes hasn't been properly added or fetched
[ -z "$needs_fetch$needs_remote" ] || exit_needswork

##
## Create rebase commands for all local branches
##

pad
heading Checking Branches

# Build lists of refs
refs_old=($(eval $(cmd git for-each-ref --shell \
                                        --format \
                                        'r=%(refname);echo "${r#refs/}";' \
                                        refs/remotes/$remote_old/)))
refs_new=($(eval $(cmd git for-each-ref --shell \
                                        --format \
                                        'r=%(refname);echo "${r#refs/}";' \
                                        refs/remotes/$remote_new/)))
refs_projects=($(eval $(cmd git for-each-ref --shell \
                                             --format \
                                             'r=%(refname);echo "${r#refs/}";' \
                                             refs/remotes/$remote_projects/)))

refs_allnew=("${refs_new[@]}" "${refs_projects[@]}")

stat Finding common refs
# Find all remote branches held in both sets
refs_common_old=()
refs_common_new=()
refs_common_projects=()
for ref in "${refs_old[@]}"; do
  ref="${ref#remotes/$remote_old/}"
  for match in "${refs_new[@]}" "${refs_projects[@]}"; do
    if [ "remotes/$remote_new/$ref" = "$match" ]; then
      refs_common_new[${#refs_common_new[@]}]="remotes/$remote_new/$ref"
      refs_common_old[${#refs_common_old[@]}]="remotes/$remote_old/$ref"
    elif [ "remotes/$remote_projects/$ref" = "$match" ]; then
      refs_common_new[${#refs_common_new[@]}]="remotes/$remote_projects/$ref"
      refs_common_old[${#refs_common_old[@]}]="remotes/$remote_old/$ref"
    fi
  done
done
vstat "Found ${#refs_common_new[@]} common refs: ${refs_common_new[*]}"

stat "Scanning for branches that need rebase. This may take a moment..."
rebase_branches=($(parse-git-branch git branch --contains $ROOT_OLD))

if [ "${#rebase_branches[@]}" -gt 0 ]; then
  stat "${#rebase_branches[@]} branches need rebasing."
  stat "Building tree hash graph of new SHAs..."
  # Array will be pairs of (matchformat hash)
  treehashes_new=($(git log --format="format:$COMMIT_MATCH_FORMAT %H" \
                            "${refs_new[@]}" "${refs_projects[@]}" \
                            ^$SYNCBASE_NEW))
  vstat "${#treehashes_new[@]} new SHAs in graph"
  for rebase_branch in "${rebase_branches[@]}"; do
    rebase_point=($(find_rebase_point "$rebase_branch"))
    if [ -n "$rebase_point" ]; then
      rebase_old_base="${rebase_point[0]:0:12}"
      rebase_new_base="${rebase_point[1]:0:12}"
      pad
      action "Branch $rebase_branch is based on the old SHAs, rebase it to its"
      action "equivalent base commit on the new SHAs with:"
      showcmd "git checkout $rebase_branch"
      showcmd "git rebase $rebase_old_base" \
        "--onto $rebase_new_base"
      cmd git log --oneline --no-walk "$rebase_old_base" "$rebase_new_base"
    else
      pad
      err "Failed to find matching commit in the new repositories for"
      err "branch $rebase_branch! This shouldn't happen :( Please try:"
      showcmd "git fetch $remote_old -p && git fetch $remote_new -p"
      err "And try again. If you still encounter this error, please make sure"
      err "You have the latest version of this script and file an issue at:"
      err "https://github.com/Nephyrin/moz-git-migrator/issues"
      pad
    fi
  done
else
  allgood "You don't appear to have any remaining branches on the old SHAs"
fi

##
## Create command to delete extra tags
##

pad
heading Checking Tags

## See if tags have been fetched from the new remote or not
tagcheck_rev="$(cmd git show-ref -s $TAGCHECK || true)"
if [ "$tagcheck_rev" != "$TAGCHECK_NEW" ]; then
  pad
  action "Your repository's tags are pointing at the old remote. Update them"
  action "explicitly from the new remote with:"
  showcmd "git fetch --tags $remote_new"
  showcmd "git fetch --tags $remote_projects"
  # Don't show final steps until these are taken care of
fi

old_tags=$(cmd git tag --contains $ROOT_OLD)
if [ -z "$old_tags" ]; then
  allgood "Your tags appear to be up to date and using the new SHAs"
else
  pad
  action "You have old tags that don't exist in the new SHAs. Verify that you"
  action "Don't want them, then delete them with the command below"
  action "NOTE: The old SHAs had a *lot* more tags, don't panic when this"
  action "      removes 100 tags!"
  showcmd git tag -d \`git tag --contains ${ROOT_OLD:0:12}\`
fi

## At this point, exit if actions have been shown during branch/tag checking
[ -z "$action_shown" ] || exit_needswork

##
## Final remote cleanup commands
##

pad
heading Remaining Cleanup
# TODO We need to detect if tags/branches exist *before* fetching remotes
stat "TODO: Advise removing the old remote if you don't need/want it"

##
## Result
##

# If we haven't bailed by now, we're all good!
pad
heading
heading Result
heading
allgood
allgood "Your repository appears to be free of non-reflog references to"
allgood "the old SHAs, you're all good -- But please take note of the caveats"
allgood "below!"
allgood
pad


err "Important Note About Reflogs:"
action "For branches moved to the new SHAs, your reflogs still contain"
action "references to the old, pre-rebase SHAs. Keep in mind that recalling"
action "these old commits into a branch means you'll re-contaminate the branch."
action "(You may re-run this script at any time to re-check for branches on the"
action "old SHAs)"
pad


# Check if we're going to run into GC issues with the loose objects
pruneexpire="$(cmd git config gc.pruneexpire || true)"
if [ "$pruneexpire" != "now" ]; then
  err Important Note About GC
  # TODO insert warning about GC config option, or steps to resolve in future
  action "Due to the way git handles stale, unreachable objects, you may run"
  action "into issues once references to the old SHAs have expired from your"
  action "reflogs. Specifically, your repository may (temporarily) grow as"
  action "large as 10GiB as the loose references are moved out of packs, and"
  action "git will begin complaining that you have too many loose objects."
  pad
  action "There are three options for dealing with this:"
  action
  action "1. Wipe your reflogs of the old SHAs now, and then prune all old"
  action "   objects immediately"
  action "   WARNING: This will irrevocably remove all reflog entries that"
  action "            occurred before moving to the new branches!"
  showcmd "git reflog expire --all --expire-unreachable=all"
  showcmd "# This will take several minutes, as it is deleting ~1.5 million"
  showcmd "# commits"
  showcmd "git gc --prune=now"
  action
  action "2. Disable the grace period for unreachable objects for this"
  action "   repository. Normally, once a reference drops from your reflogs,"
  action "   git keeps it around, unpacked(!), for a while, just in case."
  action "   Setting this removes that grace period. If you have no idea how or"
  action "   why you'd go about finding a unreachable commit that's expired"
  action "   from your reflogs, this is probably the easiest option"
  showcmd "git config gc.pruneExpire now"
  action
  action "3. Wait until this happens, and git starts complaining about"
  action "   'too many unreachable objects'. At that point follow its advice"
  action "   and run git prune as instructed. This is the best option if you"
  action "   have 10GiB to spare and think you'll remember this instruction in"
  action "   two months!"
  showcmd "git prune"

  pad
fi

exit 0
