#!/bin/bash

set -e

##
## Config
##

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

# The root commits for the trees we're aware of.
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
# to run git fetch --tags <newremote>. Unset TAGCHECK to disable.
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
heading() { echo >&2 "$(sh_c 34 1)>>$(sh_c) $(sh_c 36 2)$*$(sh_c)"; }
exit_needswork() {
  pad
  heading Result
  action "Address the issues above and then RERUN THIS SCRIPT to ensure that"
  action "your repository is properly migrated."
  pad
  exit 1
}
pad() { echo >&2 ""; }
# indent 2
action() {
  action_shown=1
  echo >&2 "  $(sh_c 33 1)##$(sh_c) $*";
}
# indent 2
allgood() { echo >&2 "  $(sh_c 32 1)##$(sh_c) $*"; }
# indent 4 (shown under actions)
showcmd() { echo >&2 "     $(sh_c 33 1):;$(sh_c) $(sh_c 33 2)$*$(sh_c)"; }
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

# Find what root commit a remote's master branch is using, with caching
remote_root()
{
  local remote="$1"
  local varname="remote_root_${remote//[^a-zA-Z]/_}"
  local root
  eval root=\$$varname
  if [ -z "$root" ]; then
    root="$(git rev-list "$remote"/master 2>/dev/null | tail -n 1)"
  fi
  # Some mirrors have 'central' as the main branch
  if [ -z "$root" ]; then
    root="$(git rev-list "$remote"/central 2>/dev/null | tail -n 1)"
  fi
  echo "$root"
}

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

# Find where a branch merges with the old SHAs
# Expects refs_remote has been filled
find_merge_point() {
  local branch="$1"
  echo $(cmd git merge-base $branch "${refs_old[@]}")
}

# Given a ref, returns ($oldbase $newbase) suitable for e.g.
#   $ git rebase $oldbase --onto $newbase
# Expects treehashes_new has been filled
find_rebase_point() {
  local branch="$1"
  local rebase_old_base="$2"
  local reachable_ref_old reachable_ref_new
  local reachable_path reachable_path_length
  local reachable_ref_offset=0

  local sig="$(cmd git log --no-walk --format="format:$COMMIT_MATCH_FORMAT" \
                           "$rebase_old_base")"
  vstat "Looking for treehash $sig"
  local candidate
  local i=0
  # treehashes is a list of pairs (treehash:matchingcommit)
  for candidate in $(echo "$treehashes_new" | egrep "^$sig"); do
    candidate="${candidate#*:}"
    if commits_identical $rebase_old_base $candidate; then
      echo $candidate
      return
    fi
  done
}

# Compare two commits from two sets of SHAs to see if they are the same
# re-written commit tree from SYNCBASE upwards
commits_identical() {
  local old="$1"
  local new="$2"
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

heading "Checking Repository"
if [ -n "$(cmd git status -s -uno)" ]; then
  err "Warning: Repository has uncommited changes, you should commit or stash"
  err "         these before running the commands below"
fi

if ! cmd git show $ROOT_OLD &>/dev/null; then
  # Repository doesn't even have the old SHAs
  no_old_shas=1
  stat "Old SHAs not present"
else
  stat "Scanning tags"
  old_tags="$(cmd git tag --contains $ROOT_OLD)"
  stat "Scanning branches"
  rebase_branches=($(parse-git-branch git branch --contains $ROOT_OLD))
fi

if [ "${#rebase_branches[@]}" -gt 0 ]; then
  # We need to fetch/add the old remote to properly find the merge point of old
  # branches
  want_old_remote=1
fi

##
## Check & find remotes
##

normalized_new="$(remote_normalize "$REMOTE_NEW")"
normalized_old="$(remote_normalize "$REMOTE_OLD")"
normalized_projects="$(remote_normalize "$REMOTE_PROJECTS")"

pad
heading Checking Remotes
remotes=($(cmd git remote))
old_remotes=()
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
    old_remotes[${#old_remotes[@]}]="$remote"
    stat "remote $remote -> mozilla-central (Old SHAs)"
  elif [ "$url" = "$normalized_projects" ]; then
    remote_projects="$remote"
    stat "remote $remote -> gecko-projects (New SHAs)"
  else
    remote_root="$(remote_root "$remote")"
    if [ "$remote_root" = "$ROOT_OLD" ]; then
      stat "remote $remote -> Unknown Old SHAs repo"
      old_remotes[${#old_remotes[@]}]="$remote"
    elif [ "$remote_root" = "$ROOT_NEW" ]; then
      stat "remote $remote -> Unknown New SHAs repo (gecko-dev based)"
    elif [ "$remote_root" = "$ROOT_PROJECTS" ]; then
      stat "remote $remote -> Unknown New SHAs repo (gecko-projects based)"
    else
      stat "remote $remote is not recognized"
    fi
  fi
done

##
## See if remote needs to be added
##

remote_check_fetch() {
  local remote="$1"
  local expected_base="$2"
  # Check that this remote has a master branch, and that is the expected tree.
  local root="$(remote_root $remote)"
  if [ -z "$root" ] || [ "$root" != "$expected_base" ]; then
    action "Remote $remote does not appear to be up to date, fetch it with:"
    showcmd "git fetch $remote"
    needs_fetch=1
  fi
}

if [ -z "$remote_old" ] && [ -n "$want_old_remote" ]; then
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

if [ "${#rebase_branches[@]}" -gt 0 ]; then
  pad
  heading Rebase Old Branches

  stat "${#rebase_branches[@]} branches need rebasing."
  stat "Building list of refs..."
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

  stat "Building tree hash graph of new SHAs..."
  # Array will be pairs of (matchformat hash)
  treehashes_new=("$(git log --format="format:$COMMIT_MATCH_FORMAT:%H" \
                            "${refs_new[@]}" "${refs_projects[@]}" \
                            ^$SYNCBASE_NEW)")
  for rebase_branch in "${rebase_branches[@]}"; do
    stat "Finding rebase point for branch $rebase_branch"
    rebase_old_base="$(cmd find_merge_point $rebase_branch)"
    vstat "Base in old SHAs for branch $rebase_branch is $rebase_old_base"
    rebase_new_base=($(cmd find_rebase_point "$rebase_branch" "$rebase_old_base"))
    if [ -n "$rebase_old_base" ] && [ -n "$rebase_new_base" ]; then
      rebase_old_base="${rebase_old_base:0:12}"
      rebase_new_base="${rebase_new_base:0:12}"
      # Check upstream
      upstream_remote="$(cmd git config branch.$rebase_branch.remote || true)"
      upstream_merge="$(cmd git config branch.$rebase_branch.merge || true)"
      upstream_merge="${upstream_merge#refs/heads/}"
      if [ -n "$upstream_merge" ] && [ -n "$upstream_remote" ]; then
        if [ "$upstream_remote" = "." ]; then
          upstream="$upstream_merge"
        else
          upstream="remotes/$upstream_remote/$upstream_merge"
        fi
        expected_base="$(cmd git merge-base "$rebase_branch" "$upstream")"
        if [ "$expected_base" != "$rebase_old_base" ]; then
          err "WARNING: This branch is based on commit ${expected_base:0:12} in"
          err "branch $upstream, but its nearest base in the mozilla-central"
          err "remote is ${rebase_old_base:0:12}. This can happen if $upstream"
          err "is not an upstream branch, or if your $remote_old remote is out"
          err "of date and needs to be fetched."
          err "Double-check that the rebase command below is doing what you"
          err "expect!"
        fi
      fi
      pad
      action "Branch $rebase_branch is based on the old SHAs, rebase it to its"
      action "equivalent base commit on the new SHAs with:"
      showcmd "git checkout $rebase_branch"
      showcmd "git rebase $rebase_old_base" \
        "--onto $rebase_new_base"

      # Check if we need to update tracking
      if [ -n "$upstream_remote" ] && [ -n "$upstream_merge" ] &&
         [ "$(remote_root "$upstream_remote")" = "$ROOT_OLD" ]; then
        match=""
        vstat "Looking for $upstream_remote -> $upstream_merge in new refs"
        for ref in "${refs_new[@]}" "${refs_projects[@]}"; do
          if [ "${ref#remotes/*/}" = "$upstream_merge" ]; then
            match="${ref#remotes/}"
            break
          fi
        done
        if [ -n "$match" ]; then
          showcmd "git branch --set-upstream-to=$match"
        else
          # This is expected, e.g. the branch is tracking your github clone with
          # old SHAs.
          action "This branch is tracking $upstream_remote/$upstream_merge,"
          action "which is based on old SHAs -- but branch $upstream_merge does"
          action "not exist in $remote_projects or $remote_new. You will need"
          action "to choose an equivalent upstream in a new remote and set it"
          action "with --set-upstream-to, e.g. to track $remote_new/master:"
          showcmd "git branch --set-upstream-to=$remote_new/master"
        fi
      fi
    else
      [ -n "$rebase_old_base" ] || rebase_old_base=UNKNOWN
      pad
      err "Failed to find rebase point for $rebase_branch. It appears to be"
      err "based on $rebase_old_base, which doesn't exist in the new remotes."
      err "This can happen if your view of the new remotes is out of date,"
      err "please try:"
      showcmd "git fetch $remote_new -p && git fetch $remote_projects -p"
      err "And try again. If you still encounter this error, make sure that you"
      err "have the latest version of this script and file an issue at:"
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

if [ -z "$old_tags" ]; then
  allgood "Your tags appear to be up to date and using the new SHAs"
else
  pad
  action "You have old tags that don't exist in the new SHAs. Verify that you"
  action "Don't want them, then delete them with the commands below"
  action "To list old tags that will be deleted:"
  showcmd "git tag --contains ${ROOT_OLD:0:12}"
  action "To delete them:"
  showcmd git tag -d \`git tag --contains ${ROOT_OLD:0:12}\`
  action "NOTE: There are a *lot* fewer tags on the new remote, so it is normal"
  action "      for this to show hundreds of tags needing deletion"
fi

## At this point, exit if actions have been shown during branch/tag checking
[ -z "$action_shown" ] || exit_needswork

##
## Final remote cleanup commands
##

if [ "${#old_remotes[@]}" -gt 0 ]; then
  pad
  heading Remove Old Remotes
  action "No branches or tags remain using the old SHAs, but old remotes still"
  action "exist. Remove them with:"
  for remote in "${old_remotes[@]}"; do
    showcmd "git remote rm $remote"
  done
  exit_needswork

##
## All good, final warnings
##

pad
heading Result

if [ -z "$no_old_shas" ]; then
  allgood "The old SHAs are not present in this repository. You're all good!"
  exit 0;
fi

# Otherwise, we're all done, but need to warn about the reflog/GC issues with
# still having old SHAs around

allgood "No branches, tags, or remotes using old SHAs remain, but please pay"
allgood "attention to the important caveats below"

pad
heading "Warning About Old Reflogs"
action "For branches moved to the new SHAs, your reflogs still contain"
action "references to the old, pre-rebase SHAs. Keep in mind that recalling"
action "these old commits into a branch means you'll re-contaminate the branch."
action "(You may re-run this script at any time to re-check for branches on the"
action "old SHAs)"
pad


# Check if we're going to run into GC issues with the loose objects
pruneexpire="$(cmd git config gc.pruneexpire || true)"
if [ "$pruneexpire" != "now" ]; then
  heading Important Note About GC
  action "Git evicts unreachable objects from packs for a grace period, before"
  action "deleting them. This mechanism does not expect you to have 1.5 million"
  action "obsolete objects. This means that when git attempts to evict the old"
  action "SHAs, it will grow your repository to ~10GiB, and then complain that"
  action "there are too many unreachable objects"
  action
  action "There are two ways of dealing with this:"
  action
  action "1. If your repository growing to 10GiB would be very bad, you can"
  action "   prevent this by disabling said grace period for this repository"
  action "   only. If you have no idea how or why you would go about finding"
  action "   an unreachable commit that has expired from your reflogs, this is"
  action "   the easiest option."
  showcmd "git config gc.pruneExpire now"
  action
  action "2. Do nothing. Git will start complaining about 'too many unreachable"
  action "   objects' when the objects expire, and recommend you delete them"
  action "   |git prune|. Take its advice, and you will be all good."
  action "   This is the best option if you have 10GiB to spare and will"
  action "   remember this instruction in two months."

  pad
fi

exit 0
