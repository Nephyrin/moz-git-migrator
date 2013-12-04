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
heading() {
  echo >&2 "$(sh_c 34 1)###$(sh_c)"
  echo >&2 "$(sh_c 34 1)###$(sh_c) $(sh_c 32 2)$*$(sh_c)"
  echo >&2 "$(sh_c 34 1)###$(sh_c)"
}
action() { echo >&2 "$(sh_c 33 1)>>$(sh_c) $*"; }
showcmd() { echo >&2 "$(sh_c 32 1)#$(sh_c)  $*"; }
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
## Sanity checks
##

if [ ! -d "$gitdir/.git" ]; then
  die "\"$gitdir\" does not appear to be a git repository"
fi

cd "$gitdir"

##
## Check & find remotes
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

normalized_new="$(remote_normalize "$REMOTE_NEW")"
normalized_old="$(remote_normalize "$REMOTE_OLD")"
normalized_projects="$(remote_normalize "$REMOTE_PROJECTS")"

# TODO better "you're all good" messages
heading Remotes
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

# FIXME need step to abort if old SHAs aren't present
if [ -z "$remote_old" ]; then
  needs_remote=1
  action "You don't currently have the old mozilla repository as a remote."
  action "The script needs this to generate rebase commands for your local"
  action "branches, temporarily add the old remote with:"
  showcmd "git remote add old-shas $REMOTE_OLD"
fi
if [ -z "$remote_new" ]; then
  needs_remote=1
  action "You don't currently have the new gecko-dev repo configured as a"
  action "remote. Add the new remote with:"
  showcmd "git remote add gecko-dev $REMOTE_NEW"
  showcmd "git fetch gecko-dev"
fi
if [ -z "$remote_projects" ]; then
  needs_remote=1
  action "You don't currently have the new gecko-projects repo configured as a"
  action "remote. Add the new remote with:"
  showcmd "git remote add gecko-projects $REMOTE_PROJECTS"
  showcmd "git fetch gecko-projects"
fi

##
## See if remote is fetched, or needs tags-fetch
##

# FIXME merge with above for stat() reasons
# FIXME if a branch is longer than any remote on the ancestry path

check_remote() {
  local remote="$1"
  local expected_base="$2"
  # Check that this remote has a master branch, and that is the expected tree.
  local root="$(cmd git rev-list remotes/"$remote"/master -- | tail -n 1)"
  if [ -z "$root" ] || [ "$root" != "$expected_base" ]; then
    action "Remote $remote does not have up to date tree data..." #FIXME
    needs_fetch=1
  fi
}

#FIXME check tags
[ -z "$remote_new" ] || check_remote "$remote_new" "$ROOT_NEW"
[ -z "$remote_projects" ] || check_remote "$remote_projects" "$ROOT_PROJECTS"

## Exit if either of the new remotes hasn't been properly added or fetched
if [ -n "$needs_fetch$needs_remote" ]; then
  action "Add and fetch the remotes listed above, then re-run this script"
  exit 1
fi

##
## Create rebase commands for all local branches
##

heading Branches
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

# Ensure a variable named e.g. revlist_remote_origin_esr17 exists, for lazily
# generating these (expensive) lists
revlist() {
  cmd git rev-list --full-history --topo-order --ancestry-path "$@"
}
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
  else
    :;
    err Failed to find matching commit
    # FIXME Give better advice (fetch --all), can this happen?
  fi
}

commits_identical() {
  [ -n "$1" ] && [ -n "$2" ] && \
  [ "$(cmd git log --pretty="format:%T%an%ae%at%cn%ce%ct%s%b" --no-walk $1)" = \
    "$(cmd git log --pretty="format:%T%an%ae%at%cn%ce%ct%s%b" --no-walk $2)" ]
}

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
      # FIXME --date-order is not infallible, sanity check commits and suggest fetch
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
        action "Branch $rebase_branch is based on $reachable_ref_old, rebase it to $reachable_ref_new with:"
        showcmd "git checkout $rebase_branch && git rebase $reachable_ref_old --onto $rebase_new_base"
      else
        # FIXME better error and advice
        err "Failed to find matching commit"
      fi
    else
      err "Branch $rebase_branch isn't reachable from any common branch..."
      #FIXME This can happen if $rebase_old_base is on a branch not in the new SHAs. We can fix it!
    fi
  done
else
  action "No local branches need rebasing"
fi

#FIXME skip if no branches to rebase

##
## Create command to delete extra tags
##

heading Tags
# FIXME replacement fetching
old_tags=$(cmd git tag --contains $ROOT_OLD)
if [ -z "$old_tags" ]; then
  action "No old tags need deleting"
else
  action "You have old tags that don't exist in the new SHAs. Verify that you"
  action "Don't want them, then delete them with:"
  showcmd git tag -d $old_tags
fi

##
## Final remote cleanup commands
##

heading Cleanup
# TODO only show this if everything else passes, otherwise give advice to re-run
# showcmd git remote rm $remote_old
stat "TODO"

##
## GC Warning + config
##

heading Warning about GC
# TODO insert warning about GC config option, or steps to resolve in future
stat "TODO"
