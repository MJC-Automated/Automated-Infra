#!/bin/bash
# === gerrit_ticket_report.sh ===
# Usage: Prepare a list of tickets separated by new lines in a file (e.g., tickets.txt)
# Then run this script with the file as an argument.
# ./gerrit-report.sh tickets.txt

# Disable git pager for non-interactive execution
export GIT_PAGER=cat

TICKET_FILE=${1:-"tickets.txt"}

if [[ -z "$TICKET_FILE" ]]; then
  echo "Usage: $0 <ticket-list-file>"
  exit 1
fi

if [[ ! -f "$TICKET_FILE" ]]; then
  echo "Error: Ticket file '$TICKET_FILE' not found!"
  exit 1
fi

# Pretty date format function
format_date() {
  date --date="$1" +"%A, %b %d, %Y, %I:%M:%S %p %Z"
}

# Function to list branches and get user selection
select_branch() {
    local prompt="$1"
    echo "$prompt"
    echo ""
    
    # Get all local and remote branches, remove duplicates and format with version sorting
    local branches=($(git branch -a | grep -v HEAD | sed 's/^[ *]*//g' | sed 's/remotes\/origin\///g' | sort -uV | grep -v '^master$' | grep -v '^main$'))
    
    if [[ ${#branches[@]} -eq 0 ]]; then
        echo "No branches found!"
        return 1
    fi
    
    # Display numbered list
    for i in "${!branches[@]}"; do
        printf "%3d) %s\n" $((i+1)) "${branches[i]}"
    done
    
    echo ""
    while true; do
        read -p "Select branch number (1-${#branches[@]}): " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#branches[@]} ]]; then
            selected_branch="${branches[$((selection-1))]}"
            echo "Selected: $selected_branch"
            echo ""
            return 0
        else
            echo "Invalid selection. Please enter a number between 1 and ${#branches[@]}."
        fi
    done
}

# Function to get ALL non-merge commits for a ticket across ALL branches
get_all_ticket_commits() {
    local ticket="$1"
    # Use --all to search across all branches, get unique commits, and EXCLUDE merge commits
    {
        git log --all --no-merges --grep="$ticket" -i --format="%H|%ct|%aI|%an|%s" 2>/dev/null
        git log --all --no-merges --grep="${ticket}:" -i --format="%H|%ct|%aI|%an|%s" 2>/dev/null
        git log --all --no-merges --grep="${ticket} " -i --format="%H|%ct|%aI|%an|%s" 2>/dev/null
        git log --all --no-merges --grep="\\b${ticket}\\b" -i --format="%H|%ct|%aI|%an|%s" 2>/dev/null
    } | sort -u
}

# Function to get Change-Id from commit
get_change_id() {
    local commit_hash="$1"
    git show -s --format=%B "$commit_hash" 2>/dev/null | grep -i "Change-Id:" | awk '{print $2}' | head -1
}

# Function to check if a change is present in other branches and return the branch name
is_change_in_branches_with_details() {
    local commit_hash="$1"
    shift
    local branches_to_check=("$@")
    local change_id=$(get_change_id "$commit_hash")
    if [[ -z "$change_id" ]]; then return 1; fi
    for branch in "${branches_to_check[@]}"; do
        if git log "$branch" "origin/$branch" --grep="Change-Id: $change_id" -F --format="%H" 2>/dev/null | grep -q .; then
            echo "$branch"
            return 0
        fi
    done
    return 1
}

# Function to check if a change (via its Change-Id) is present in other branches.
is_change_in_branches() {
    local commit_hash="$1"
    shift
    local branches_to_check=("$@")
    local change_id=$(get_change_id "$commit_hash")
    if [[ -z "$change_id" ]]; then return 1; fi
    for branch in "${branches_to_check[@]}"; do
        if git log "$branch" "origin/$branch" --grep="Change-Id: $change_id" -F --format="%H" 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

# Function to check if a specific commit is in production and return reason
is_commit_in_production_with_reason() {
    local commit_hash="$1"
    local cutoff_timestamp="$2"
    local last_main_clone_branch="$3"
    shift 3
    local branches_to_check=("$@")
    local commit_timestamp=$(git log -1 --format="%ct" "$commit_hash" 2>/dev/null)
    if [[ -z "$commit_timestamp" ]]; then return 1; fi
    
    if [[ "$commit_timestamp" -lt "$cutoff_timestamp" ]]; then
        echo "Deployed in main branch clone ($last_main_clone_branch)"
        return 0
    fi
    
    if [[ ${#branches_to_check[@]} -gt 0 ]]; then
        local branch_found=$(is_change_in_branches_with_details "$commit_hash" "${branches_to_check[@]}")
        if [[ -n "$branch_found" ]]; then
            echo "Cherry-picked in branch: $branch_found"
            return 0
        fi
    fi
    return 1
}

# Function to check if a specific commit is in production (by date or by Change-Id)
is_commit_in_production() {
    local commit_hash="$1"
    local cutoff_timestamp="$2"
    shift 2
    local branches_to_check=("$@")
    local commit_timestamp=$(git log -1 --format="%ct" "$commit_hash" 2>/dev/null)
    if [[ -z "$commit_timestamp" ]]; then return 1; fi
    if [[ "$commit_timestamp" -lt "$cutoff_timestamp" ]]; then return 0; fi
    if [[ ${#branches_to_check[@]} -gt 0 ]]; then
        if is_change_in_branches "$commit_hash" "${branches_to_check[@]}"; then return 0; fi
    fi
    return 1
}

# Analyzes a PRE-SUPPLIED list of commits.
analyze_commit_list_status() {
    local commit_list="$1"
    local cutoff_timestamp="$2"
    shift 2
    local branches_to_check=("$@")
    
    if [[ -z "$commit_list" ]]; then echo "NOT_FOUND"; return 1; fi
    
    local commits_in_prod=0; local commits_new=0; local total_commits=0
    declare -A seen_changes
    
    while IFS='|' read -r commit_hash _; do
        [[ -z "$commit_hash" ]] && continue
        local change_id=$(get_change_id "$commit_hash")
        if [[ -n "$change_id" && -n "${seen_changes[$change_id]}" ]]; then continue; fi
        if [[ -n "$change_id" ]]; then seen_changes["$change_id"]=1; fi
        
        total_commits=$((total_commits + 1))
        if is_commit_in_production "$commit_hash" "$cutoff_timestamp" "${branches_to_check[@]}"; then
            commits_in_prod=$((commits_in_prod + 1))
        else
            commits_new=$((commits_new + 1))
        fi
    done <<< "$commit_list"
    
    if [[ $total_commits -eq 0 ]]; then echo "NOT_FOUND"; return 1; fi
    if [[ $commits_in_prod -eq $total_commits ]]; then echo "FULL";
    elif [[ $commits_in_prod -gt 0 && $commits_new -gt 0 ]]; then echo "PARTIAL";
    elif [[ $commits_new -eq $total_commits ]]; then echo "NEW";
    else echo "UNKNOWN"; fi
}

# Function to get ticket subjects
get_ticket_subjects() {
    local ticket_file="$1"
    echo "### Ticket List with Subjects"; echo ""
    while read -r TICKET; do
        [[ -z "$TICKET" ]] && continue
        local subject=$(git log --all --no-merges --grep="$TICKET" -i --format="%s" -1 2>/dev/null)
        if [[ -n "$subject" ]]; then echo "- **$TICKET**: $subject";
        else echo "- **$TICKET**: *(No commits found)*"; fi
    done < "$ticket_file"
    echo ""
}

# --- Setup ---
echo "=== RELEASE MANAGEMENT SETUP ==="; echo ""
select_branch "Select the LAST RELEASE BRANCH (The most recent production branch):"
LAST_RELEASE_BRANCH="$selected_branch"
select_branch "Select the LAST MAIN-BRANCH CLONE RELEASE (The baseline for this analysis):"
LAST_MAIN_CLONE_BRANCH="$selected_branch"
echo "Getting release information..."; echo ""
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git checkout "$LAST_RELEASE_BRANCH" >/dev/null 2>&1
LAST_RELEASE_PRETTY=$(format_date "$(git log -1 --format=%aI)")
git checkout "$LAST_MAIN_CLONE_BRANCH" >/dev/null 2>&1
LAST_MAIN_CLONE_PRETTY=$(format_date "$(git log -1 --format=%aI)")
MAIN_CLONE_TIMESTAMP=$(git log -1 --format="%ct")
git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1

# --- Identify consecutive branches for checking ---
all_branches_sorted=($(git branch -a | grep -v HEAD | sed 's/^[ *]*//g;s/remotes\/origin\///g' | sort -uV))
last_main_clone_index=-1; last_release_index=-1
for i in "${!all_branches_sorted[@]}"; do
   if [[ "${all_branches_sorted[$i]}" == "$LAST_MAIN_CLONE_BRANCH" ]]; then last_main_clone_index=$i; fi
   if [[ "${all_branches_sorted[$i]}" == "$LAST_RELEASE_BRANCH" ]]; then last_release_index=$i; fi
done
CONSECUTIVE_BRANCHES=()
if [[ $last_main_clone_index -ne -1 && $last_release_index -ne -1 && $last_main_clone_index -lt $last_release_index ]]; then
    for (( i=last_main_clone_index + 1; i <= last_release_index; i++ )); do
        CONSECUTIVE_BRANCHES+=("${all_branches_sorted[i]}")
    done
fi

# --- Report Generation ---
echo "# Gerrit Ticket Report - Release Management"; echo ""
echo "**Generated on:** $(date)"; echo ""
echo "**Generated by:** Emmanuel Kipkorir - Release Manager"; echo ""
echo "**Repository Used:** $(basename "$(git rev-parse --show-toplevel)")"; echo ""
echo "**Branch Used:** $(git rev-parse --abbrev-ref HEAD)"; echo ""
echo "## Release Information"; echo ""
echo "- **Last Release Branch:** $LAST_RELEASE_BRANCH"
echo "- **Last Release Date:** $LAST_RELEASE_PRETTY"
echo "- **Baseline Branch (Main Clone):** $LAST_MAIN_CLONE_BRANCH"
echo "- **Baseline Date:** $LAST_MAIN_CLONE_PRETTY"
echo "- **Production Cutoff Timestamp:** $MAIN_CLONE_TIMESTAMP ($(format_date "@$MAIN_CLONE_TIMESTAMP"))"
echo ""
get_ticket_subjects "$TICKET_FILE"
if [[ ${#CONSECUTIVE_BRANCHES[@]} -gt 0 ]]; then
    echo "### Consecutive Branches Checked for patches (via Change-Id)"; echo ""
    echo "In addition to the baseline date, commits were checked for presence in the following branches:"
    printf -- "- %s\n" "${CONSECUTIVE_BRANCHES[@]}"; echo ""
fi

declare -A TICKET_STATUSES

# --- Main Processing Loop ---
while read -r TICKET; do
  [[ -z "$TICKET" ]] && continue
  
  # SIMPLIFIED LOGIC:
  # 1. Get ALL unique, non-merge commits for the ticket. This is the single source of truth.
  all_feature_commits=$(get_all_ticket_commits "$TICKET")
  
  # 2. Analyze this complete list to get the status.
  PRODUCTION_STATUS=$(analyze_commit_list_status "$all_feature_commits" "$MAIN_CLONE_TIMESTAMP" "${CONSECUTIVE_BRANCHES[@]}")
  TICKET_STATUSES["$TICKET"]="$PRODUCTION_STATUS"
  
  STATUS_INDICATOR=""
  case "$PRODUCTION_STATUS" in
    "FULL") STATUS_INDICATOR=" 🔴 **FULLY IN PRODUCTION**";;
    "PARTIAL") STATUS_INDICATOR=" 🟡 **PARTIALLY IN PRODUCTION**";;
    "NEW") STATUS_INDICATOR=" ✅ **NEW FOR RELEASE**";;
    "NOT_FOUND") STATUS_INDICATOR=" ❌ **NOT FOUND**";;
  esac
  
  echo "## Ticket: $TICKET$STATUS_INDICATOR"; echo ""
  
  # 3. Display the complete, sorted list of commits.
  if [[ -n "$all_feature_commits" ]]; then
    echo "### Commits"; echo ""
    declare -A seen_changes_display
    # Sort by the second field (timestamp), numerically (oldest first).
    sorted_commits=$(echo "$all_feature_commits" | sort -t'|' -k2,2n)
    
    while IFS='|' read -r commit_hash commit_timestamp commit_date author subject; do
      [[ -z "$commit_hash" ]] && continue
      change_id=$(get_change_id "$commit_hash")
      if [[ -n "$change_id" && -n "${seen_changes_display[$change_id]}" ]]; then continue; fi
      if [[ -n "$change_id" ]]; then seen_changes_display["$change_id"]=1; fi
      
      PRETTYDATE=$(format_date "$commit_date")
      PRODUCTION_REASON=$(is_commit_in_production_with_reason "$commit_hash" "$MAIN_CLONE_TIMESTAMP" "$LAST_MAIN_CLONE_BRANCH" "${CONSECUTIVE_BRANCHES[@]}")
      COMMIT_STATUS=""
      if [[ -n "$PRODUCTION_REASON" ]]; then
        COMMIT_STATUS=" 🔴 **IN PRODUCTION** (*$PRODUCTION_REASON*)"
      fi
      
      echo "#### Commit: \`$commit_hash\`$COMMIT_STATUS"; echo ""
      echo "- **Date:** $PRETTYDATE"; echo "- **Owner:** $author"
      echo "- **Change ID:** ${change_id:-"Not found"}"; echo "- **Subject:** $subject"
      echo "- **Files Changed:**"; echo '```'; git show --name-status --format="" "$commit_hash" 2>/dev/null || echo "Unable to retrieve file changes"; echo '```'; echo ""
    done <<< "$sorted_commits"
  else
    echo "❌ **No feature commits found for $TICKET**"; echo ""
  fi
  
  echo "---"; echo ""
done < "$TICKET_FILE"

# --- Summary Section ---
echo "## Summary"; echo ""
echo "Report completed at: $(date)"; echo ""
echo "### Production Status Summary"; echo ""
TOTAL_TICKETS=0; FULL_PRODUCTION_TICKETS=0; PARTIAL_PRODUCTION_TICKETS=0; NEW_TICKETS=0; NOT_FOUND_TICKETS=0
while read -r TICKET; do
  [[ -z "$TICKET" ]] && continue
  TOTAL_TICKETS=$((TOTAL_TICKETS + 1))
  PRODUCTION_STATUS=${TICKET_STATUSES["$TICKET"]}
  case "$PRODUCTION_STATUS" in
    "FULL") echo "- 🔴 **$TICKET** - Fully in production"; FULL_PRODUCTION_TICKETS=$((FULL_PRODUCTION_TICKETS + 1));;
    "PARTIAL") echo "- 🟡 **$TICKET** - Partially in production"; PARTIAL_PRODUCTION_TICKETS=$((PARTIAL_PRODUCTION_TICKETS + 1));;
    "NEW") echo "- ✅ **$TICKET** - New ticket for this release"; NEW_TICKETS=$((NEW_TICKETS + 1));;
    *) echo "- ❌ **$TICKET** - No commits found"; NOT_FOUND_TICKETS=$((NOT_FOUND_TICKETS + 1));;
  esac
done < "$TICKET_FILE"
echo ""
echo "**Total Tickets:** $TOTAL_TICKETS"; echo ""
echo "**Fully in Production:** $FULL_PRODUCTION_TICKETS"
echo ""
echo "**Partially in Production:** $PARTIAL_PRODUCTION_TICKETS (⚠️ Mixed status - requires careful review)"
echo ""
echo "**New for Release:** $NEW_TICKETS"; 
echo ""
echo "**Not Found:** $NOT_FOUND_TICKETS"; echo ""
echo "**Release Candidates:** $((NEW_TICKETS + PARTIAL_PRODUCTION_TICKETS))"; echo ""
echo "**Note:** Production status is determined by checking if a commit's timestamp is before the baseline date **OR** if its **Change-Id** exists in any subsequent release branches up to **$LAST_RELEASE_BRANCH**."
echo ""
echo "**Legend:**"; echo "- 🔴 FULLY IN PRODUCTION: All commits are already deployed"
echo "- 🟡 PARTIALLY IN PRODUCTION: Some commits deployed, some new"
echo "- ✅ NEW FOR RELEASE: All commits are new and ready for deployment"
echo "- ❌ NOT FOUND: No commits found for the ticket"
echo ""
echo "                     ========================================== End of Report =================================             "