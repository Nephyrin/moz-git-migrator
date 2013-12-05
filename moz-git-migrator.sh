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
TAGCHECK_OLD=cf2c1cb76f8ffb0883876a69548f86905a27077b

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
  echo -n -e "\e[$b${c}m"
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

# Generate our rev-lists with identical options so they can be compared
revlist() {
  cmd git rev-list --full-history --topo-order --ancestry-path "$@"
}

#FIXME old head > new head syncbase length implies fetch needed

# This repeats a rev list, finding the first *parallel* branch to $unwanted and
# listing from there.
#
# This is useful if the new remote has more history than the old remote (which
# may no longer be being updated). The ancestry path could contain a parallel
# branch that was merged downstream of the commit we're looking for, appearing
# first in the flattened ancestry list.
#
# Old view:        New View:
#                  C-> o 7  <---  If 6/5 is the first parent, 3/4 will appear
#                     / \         last in the graph, messing up our count.
# A-> o 4      B-> 4 o   o 6 <-A
#     |              |   |
#     o 3          3 o   o 5
#    /                \ /
#   o 2                o 2
#   |                  |
#   o 1                o 1 <-- Root commits
#
# We get a revlist and count up from the bottom commit, but the new parallel
# branch means we end up at B when counting up 4 instead of A. So, when we find
# a non-matching commit (B), we pass it to this, which finds the next merge (C),
# then finds the parent that *doesn't* contain B, repeating the listing. At this
# point A should be at count 4 from the bottom.  If there are nested parallel
# branches, we may need to repeat the process to find the commit we want.
revlist_omit_downstream_branch() {
  local base="$1"
  local origin="$2"
  local unwanted="$3"
  local list=($(revlist --merges $origin ^$unwanted ^$base))
  local downstream_merge=${list[$((${#list[@]} - 1))]}
  if ! cmd git merge-base --is-ancestor $unwanted $downstream_merge^; then
    cmd revlist $base..$downstream_merge^
  elif ! cmd git merge-base --is-ancestor $unwanted $downstream_merge^2; then
    cmd revlist $base..$downstream_merge^2
  fi
}

# Compare two commits from two sets of SHAs to see if they are identical and
# represent an identical tree. Compares tree hash, author, commitor, timestamps,
# as well as that the resultant tree is identical (git diff is empty).
commits_identical() {
  [ -n "$1" ] && [ -n "$2" ] && \
  [ "$(cmd git log --pretty="format:%T%an%ae%at%cn%ce%ct%s%b" --no-walk $1)" = \
    "$(cmd git log --pretty="format:%T%an%ae%at%cn%ce%ct%s%b" --no-walk $2)" ] \
  && [ -z "$(cmd git diff $1 $2)" ]
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
  for rebase_branch in "${rebase_branches[@]}"; do
    unset reachable_ref
    rebase_old_base=$(cmd git merge-base $rebase_branch "${refs_old[@]}")
    vstat "Base in old SHAs for branch $rebase_branch is $rebase_old_base"
    reachable_ref_offset=0
    for ref in "${refs_common_old[@]}"; do
      if cmd git merge-base --is-ancestor $rebase_old_base $ref; then
        vstat "Found reachable: $ref"
        reachable_ref_old="$ref"
        reachable_ref_new="${refs_common_new[$reachable_ref_offset]}"
        break
      fi
      (( ++reachable_ref_offset ))
    done
    if [ -n "$reachable_ref_old" ]; then
      # FIXME more error checking
      reachable_path_length=$(revlist --count $SYNCBASE_OLD..$rebase_old_base)
      vstat "Reachable path length is $reachable_path_length"
      reachable_path=($(revlist $SYNCBASE_NEW..$reachable_ref_new))
      while [ -z "$rebase_new_base" ] && [ -n "$reachable_path" ]; do
        # FIXME bail if lengths don't match
        if [ "${#reachable_path[@]}" -lt "$reachable_path_length" ]; then
          vstat "New reachable path is less than desired length, bailing"
          break
        fi
        candidate=${reachable_path[$((${#reachable_path[@]} - $reachable_path_length))]}
        if commits_identical $candidate $rebase_old_base; then
          rebase_new_base="$candidate"
        else
          vstat "Commits not identical, attempting to find parallel commit"
          reachable_path=($(revlist_omit_downstream_branch $SYNCBASE_NEW $reachable_ref_new $candidate))
        fi
      done
      if [ -n "$rebase_new_base" ]; then
        pad
        action "Branch $rebase_branch is based on the old SHAs, rebase it to" \
               "its equivilent base commit on the new SHAs with:"
        showcmd "git checkout $rebase_branch"
        showcmd "git rebase ${rebase_old_base:0:12}" \
                "--onto ${rebase_new_base:0:12}"
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
    else
      err "Branch $rebase_branch isn't reachable from any common branch..."
      #FIXME This can happen if $rebase_old_base is on a branch not in the new SHAs. We can fix it!
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
fi

# FIXME replacement fetching
old_tags=$(cmd git tag --contains $ROOT_OLD)
if [ -z "$old_tags" ]; then
  allgood "Your tags appear to be up to date and using the new SHAs"
else
  pad
  action "You have old tags that don't exist in the new SHAs. Verify that you"
  action "Don't want them, then delete them with:"
  showcmd git tag -d \`git tag --contains ${ROOT_OLD:0:12}\`
fi

## At this point, exit if actions have been shown during branch/tag checking
[ -z "$action_shown" ] || exit_needswork

##
## Final remote cleanup commands
##

pad
heading Remaining Cleanup
# TODO only show this if everything else passes, otherwise give advice to re-run
# showcmd git remote rm $remote_old
stat "TODO"

##
## Result
##

# If we haven't bailed by now, we're all good!
pad
heading Result
allgood "Your repository appears to be free of non-reflog references to" \
        "the old SHAs, you're all good!"

pad
heading Important Note About GC
# TODO insert warning about GC config option, or steps to resolve in future
stat "TODO"

pad

exit 0
