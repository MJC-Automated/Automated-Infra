# Gerrit Ticket Report Script - Comprehensive Guide

## Overview

The `gerrit-report.sh` script is a sophisticated release management tool that analyzes the production status of software tickets by examining commit history across multiple release branches. It provides Release Managers with detailed insights into which changes have been deployed, which are new, and which have mixed deployment status.

This script is particularly valuable in environments using:

- **Gerrit** for code review and change management
- **Git** for version control with multiple release branches
- **Change-Id** based commit tracking (standard in Gerrit workflows)
- **Cherry-picking** for selective feature deployment across branches

## Core Features

### 🎯 **Interactive Branch Selection**

The script dynamically discovers all available branches and presents them in a user-friendly numbered menu, allowing precise selection of:

- **Last Release Branch**: The most recent production deployment
- **Baseline Branch**: The reference point for determining what's "already in production"

### 🔍 **Comprehensive Commit Discovery**

Uses multiple search patterns to find ticket-related commits:

<<<<<<< HEAD
- Direct ticket references: `TICKET-28422`
- Colon-separated format: `TICKET-28422:`
- Space-separated format: `TICKET-28422`
- Word boundary matching: `\bPROJECT-28422\b`
=======
- Direct ticket references: `GIS-28422`
- Colon-separated format: `GIS-28422:`
- Space-separated format: `GIS-28422`
- Word boundary matching: `\bGIS-28422\b`
>>>>>>> terraform-proxmox-automated-infra

### 🏷️ **Change-Id Based Tracking**

Leverages Gerrit's Change-Id system to track commits across branches, enabling accurate detection of:

- Cherry-picked commits
- Backported fixes
- Cross-branch deployments

### 📊 **Intelligent Status Analysis**

Provides four distinct status categories with visual indicators:

- ✅ **NEW FOR RELEASE**: Ready for deployment
- 🟡 **PARTIALLY IN PRODUCTION**: Mixed deployment status (requires review)
- 🔴 **FULLY IN PRODUCTION**: Already deployed
- ❌ **NOT FOUND**: No commits found

## The Ticket Lifecycle: From Development to Production

Understanding how tickets move through the development and deployment pipeline is crucial for interpreting the script's output. Let's examine this through real examples from your sample reports.

### Stage 1: Development and Initial Commit

When developers work on a ticket, they create commits with the ticket ID in the subject line. Each commit receives a unique **Change-Id** from Gerrit:

<<<<<<< HEAD
Example: TICKET-28422 (Budget Assignment Feature)

```text
=======
Example: GIS-28422 (Budget Assignment Feature)

```
>>>>>>> terraform-proxmox-automated-infra
Commit: 8f24fc448c27ad123bbeebc2748387d27568b69f
Date: Saturday, Mar 29, 2025, 01:43:36 PM EAST
Owner: example.owner
Change-Id: Ie5e3c9a73c934677bedbaa5a915ec52f66e1a524
Subject: TICKET-28422-Ability to Assign Budget To A Unit
```

This represents the initial implementation of the feature, creating new database tables, UI components, and business logic.

### Stage 2: Iterative Development

Most tickets involve multiple commits as developers refine the implementation:

<<<<<<< HEAD
**TICKET-28422 Evolution:**
=======
**GIS-28422 Evolution:**
>>>>>>> terraform-proxmox-automated-infra

1. **March 29**: Initial implementation (38 files changed)
2. **April 12**: Refinements and additional features (45 files changed)  
3. **May 02**: Bug fixes and audit trails (6 files changed)
4. **May 20**: Post-baseline improvements (7 files changed)
5. **June 12**: Final enhancements (11 files changed)

### Stage 3: Production Deployment Analysis

The script determines production status using two key mechanisms:

#### **Mechanism A: Baseline Date Comparison**

The script establishes a "Production Cutoff Timestamp" from the baseline branch. Any commit before this date is considered deployed.

<<<<<<< HEAD
**Example Analysis for TICKET-28422:**

- **Baseline**: RE_004.0.0_CLIENT_A (May 15, 2025, 05:31:56 PM)
=======
**Example Analysis for GIS-28422:**

- **Baseline**: RE_004.0.0_MUTUAL (May 15, 2025, 05:31:56 PM)
>>>>>>> terraform-proxmox-automated-infra
- **Cutoff Timestamp**: 1747319516

**Commits Analysis:**

- **Commit 1** (Mar 29): ✅ Before cutoff → **IN PRODUCTION**
- **Commit 2** (Apr 12): ✅ Before cutoff → **IN PRODUCTION**  
- **Commit 3** (May 02): ✅ Before cutoff → **IN PRODUCTION**
- **Commit 4** (May 20): ❌ After cutoff → **NEW**
- **Commit 5** (Jun 12): ❌ After cutoff → **NEW**

#### **Mechanism B: Cross-Branch Change-Id Detection**

The script searches for matching Change-Ids in subsequent release branches to identify cherry-picked commits.

<<<<<<< HEAD
Example: TICKET-28676 (Loss Participation Report)

```text
=======
Example: GIS-28676 (Loss Participation Report)

```
>>>>>>> terraform-proxmox-automated-infra
Commit: c28beae8a7481fe9c9ce27115db54b84deb81754
Date: Saturday, May 17, 2025, 09:41:10 PM EAST (After baseline)
Status: 🔴 IN PRODUCTION (Cherry-picked in branch: 002.1.0_CLIENT_A)
Change-Id: Ieeb6b02f28695b02bf353ea1304300edf3aaa4b6
```

Even though this commit was made after the baseline date, the script detected its Change-Id in the `002.1.0_CLIENT_A` branch, confirming it was cherry-picked for production deployment.

## Detailed Status Categories with Real Examples

### ✅ **NEW FOR RELEASE Status**

<<<<<<< HEAD
Example: TICKET-30315 (Refund Processing Fix)

```text
=======
Example: GIS-30315 (Refund Processing Fix)

```
>>>>>>> terraform-proxmox-automated-infra
Total Commits: 1
All Commits: After baseline date
Cross-Branch Presence: None found
Status: ✅ NEW FOR RELEASE
```

**Interpretation**: This is a pure new ticket. The single commit was made on June 5, 2025 (after the May 15 baseline), and its Change-Id doesn't exist in any subsequent release branches. This ticket is ready for inclusion in the next release.

<<<<<<< HEAD
Example: TICKET-30068 (Claim Revision Feedback)

```text
=======
Example: GIS-30068 (Claim Revision Feedback)

```
>>>>>>> terraform-proxmox-automated-infra
Total Commits: 3
Commit Dates: Jun 26, Jul 01, Sep 03, 2025
All Commits: After baseline date  
Cross-Branch Presence: None found
Status: ✅ NEW FOR RELEASE
```

**Interpretation**: This ticket had ongoing development with three commits, all made after the baseline. None were cherry-picked to other branches, making this entirely new functionality ready for release.

### 🟡 **PARTIALLY IN PRODUCTION Status**

<<<<<<< HEAD
Example: TICKET-28477 (Budget Print Feature)

```text
=======
Example: GIS-28477 (Budget Print Feature)

```
>>>>>>> terraform-proxmox-automated-infra
Total Commits: 4
Production Status:
- Commit 1 (Apr 19): 🔴 Before baseline → IN PRODUCTION
- Commit 2 (May 26): ❌ After baseline → NEW
- Commit 3 (May 27): 🔴 Cherry-picked to 002.1.0_CLIENT_A → IN PRODUCTION  
- Commit 4 (May 29): ❌ After baseline, not cherry-picked → NEW
Status: 🟡 PARTIALLY IN PRODUCTION
```

**Interpretation**: This represents a complex scenario where the ticket has mixed deployment status:

- 50% of commits are already in production (2 out of 4)
- 50% are new and need deployment
- The cherry-picking of commit 3 suggests urgent bug fixes were deployed selectively

**⚠️ Action Required**: Manual review needed to understand why not all commits were deployed together and whether the remaining commits are still needed.

<<<<<<< HEAD
Example: TICKET-28676 (Loss Participation Report)

```text
=======
Example: GIS-28676 (Loss Participation Report)

```
>>>>>>> terraform-proxmox-automated-infra
Total Commits: 6
Production Status:
- Commits 1-4: 🔴 IN PRODUCTION (3 by baseline date, 1 cherry-picked)
- Commits 5-6: ❌ NEW (June commits after baseline)
Status: 🟡 PARTIALLY IN PRODUCTION  
```

**Interpretation**: This ticket shows typical ongoing development where initial implementation was deployed, but subsequent enhancements and bug fixes remain undeployed.

### 🔴 **FULLY IN PRODUCTION Status**

<<<<<<< HEAD
Example: Hypothetical TICKET-29000

```text
=======
Example: Hypothetical GIS-29000

```
>>>>>>> terraform-proxmox-automated-infra
Total Commits: 3
All Commit Dates: Before May 15, 2025 baseline
Cross-Branch Analysis: Not needed (all commits pre-baseline)
Status: 🔴 FULLY IN PRODUCTION
```

**Interpretation**: Every commit for this ticket was made before the production cutoff date. The entire feature/fix is already deployed and should not be included in the new release bundle.

### ❌ **NOT FOUND Status**

<<<<<<< HEAD
Example: Hypothetical TICKET-99999

```text
=======
Example: Hypothetical GIS-99999

```
>>>>>>> terraform-proxmox-automated-infra
Search Results: No commits found
Possible Causes:
- Typo in ticket number
- Ticket exists but no code changes committed
- Different commit message format used
- Ticket in different repository
Status: ❌ NOT FOUND
```

**Interpretation**: The script couldn't find any commits associated with this ticket ID, requiring manual investigation.

## Advanced Scenarios and Edge Cases

### **Scenario 1: Emergency Hotfixes**

**Example Pattern**:

<<<<<<< HEAD
```text
Ticket: TICKET-URGENT-001
=======
```
Ticket: GIS-URGENT-001
>>>>>>> terraform-proxmox-automated-infra
Commit 1: May 10 (Before baseline) → Original implementation
Commit 2: May 20 (After baseline) → Critical bug fix
Status: 🟡 PARTIALLY IN PRODUCTION

Follow-up Analysis:
- Check if Commit 2 was cherry-picked to hotfix branch
- Verify if emergency deployment occurred outside normal process
```

### **Scenario 2: Feature Rollbacks**

**Example Pattern**:

<<<<<<< HEAD
```text
Ticket: TICKET-28422
=======
```
Ticket: GIS-28422
>>>>>>> terraform-proxmox-automated-infra
Commits 1-3: Before baseline → Original feature deployed
Commit 4: After baseline → "Rollback changes due to production issue"  
Status: 🟡 PARTIALLY IN PRODUCTION

Interpretation: Feature was deployed then partially rolled back
Action: Review rollback commit to understand production impact
```

### **Scenario 3: Cross-Repository Dependencies**

**Example Pattern**:

<<<<<<< HEAD
```text
Ticket: TICKET-30000 (Frontend changes)
=======
```
Ticket: GIS-30000 (Frontend changes)
>>>>>>> terraform-proxmox-automated-infra
Status: ✅ NEW FOR RELEASE
Related: TICKET-30001 (Backend changes in different repo)
Status: Unknown (requires separate analysis)

Action Required: Ensure both repositories are analyzed for complete feature deployment
```

## Technical Deep Dive: How the Script Works

### **Phase 1: Commit Discovery Commands**

The script uses a sophisticated multi-pattern search:

```bash
# Primary search patterns
git log --all --no-merges --grep="TICKET-28422" -i --format="%H|%ct|%aI|%an|%s"
git log --all --no-merges --grep="TICKET-28422:" -i --format="%H|%ct|%aI|%an|%s"
git log --all --no-merges --grep="TICKET-28422 " -i --format="%H|%ct|%aI|%an|%s"
git log --all --no-merges --grep="\bPROJECT-28422\b" -i --format="%H|%ct|%aI|%an|%s"
```

**Format String Breakdown**:

- `%H`: Full 40-character commit hash (unique identifier)
- `%ct`: Commit timestamp (Unix epoch seconds for comparison)
- `%aI`: ISO 8601 author date (human-readable)
- `%an`: Author name (for accountability)
- `%s`: Subject line (ticket verification)

### **Phase 2: Change-Id Extraction**

```bash
# Extract Change-Id from commit message
git show -s --format=%B "$commit_hash" | grep -i "Change-Id:" | awk '{print $2}' | head -1
```

**Pipeline Explanation**:

- `git show -s --format=%B`: Get full commit message body
- `grep -i "Change-Id:"`: Find Change-Id line (case-insensitive)
- `awk '{print $2}'`: Extract second field (the actual Change-Id)
- `head -1`: Take first match (in case of duplicates)

### **Phase 3: Cross-Branch Analysis**

```bash
# Check if Change-Id exists in specific branch
git log "$branch" "origin/$branch" --grep="Change-Id: $change_id" -F --format="%H"
```

**Command Breakdown**:

- `"$branch" "origin/$branch"`: Search both local and remote refs
- `--grep="Change-Id: $change_id"`: Exact Change-Id match
- `-F`: Treat pattern as fixed string (not regex)
- `--format="%H"`: Return only commit hashes

### **Phase 4: Status Aggregation Logic**

```bash
# Simplified decision logic
if [[ $commits_in_prod -eq $total_commits ]]; then 
    echo "FULL"
elif [[ $commits_in_prod -gt 0 && $commits_new -gt 0 ]]; then 
    echo "PARTIAL"
elif [[ $commits_new -eq $total_commits ]]; then 
    echo "NEW"
else 
    echo "UNKNOWN"
fi
```

## Interpreting the Generated Reports

### **Header Section Analysis**

```markdown
## Release Information
- **Last Release Branch:** RE_004.1.0_CLIENT_A
- **Last Release Date:** Saturday, May 31, 2025, 08:57:37 PM EAST
- **Baseline Branch (Main Clone):** RE_004.0.0_CLIENT_A  
- **Baseline Date:** Thursday, May 15, 2025, 05:31:56 PM EAST
- **Production Cutoff Timestamp:** 1747319516
```

**Key Insights**:

- **16-day window**: Between baseline (May 15) and last release (May 31)
- **Consecutive branches**: Script will check RE_004.1.0_CLIENT_A for cherry-picks
- **Timestamp**: Any commit before 1747319516 is considered deployed

### **Ticket Subject Verification**

```markdown
### Ticket List with Subjects
- **TICKET-28422**: TICKET-28422-Ability to Assign Budget To A Unit
- **TICKET-30315**: TICKET-30315 Inability to Process Refunds for Inhouse Agents
- **TICKET-30526**: TICKET-30526 Unauthorized Claim Data Entry Control...
```

**Purpose**: Confirms the script found commits for each ticket and shows the actual functionality being tracked.

### **Individual Ticket Analysis**

Each ticket section provides:

1. **Status Header**: Visual indicator and classification
2. **Commit Timeline**: Chronological list of all related commits
3. **Production Markers**: Clear indication of deployment status per commit
4. **File Changes**: Technical details of what was modified
5. **Change-Id Tracking**: Gerrit integration for cross-branch analysis

### **Summary Section Interpretation**

```markdown
**Total Tickets:** 12
**Fully in Production:** 0
**Partially in Production:** 1 (⚠️ Mixed status - requires careful review)  
**New for Release:** 11
**Not Found:** 0
**Release Candidates:** 12
```

**Analysis**:

- **83% new tickets** (11/12): Healthy release with substantial new functionality
- **8% partial tickets** (1/12): Minimal technical debt from mixed deployments
- **0% already deployed**: No wasted effort on already-released features
- **100% found**: Complete ticket tracking, no data quality issues

## Best Practices for Release Management

### **Pre-Release Analysis**

1. **Focus on Partial Tickets**: Prioritize manual review of 🟡 PARTIALLY IN PRODUCTION tickets
2. **Validate New Tickets**: Confirm ✅ NEW FOR RELEASE tickets are actually ready
3. **Investigate Not Found**: Research ❌ NOT FOUND tickets for potential issues

### **Cross-Branch Coordination**  

1. **Cherry-pick Tracking**: Use Change-Id information to understand selective deployments
2. **Dependency Analysis**: Consider related tickets that might span multiple repositories
3. **Rollback Detection**: Look for reverting commits that might indicate production issues

### **Documentation Standards**

1. **Consistent Naming**: Ensure ticket IDs are consistently formatted in commit messages
2. **Change-Id Preservation**: Never modify Change-Id values when cherry-picking
3. **Branch Strategy**: Maintain clear naming conventions for release branches

## Troubleshooting Common Issues

### **Issue**: Script reports incorrect status

**Possible Causes**:

- Inconsistent commit message formatting
- Missing or modified Change-Id values  
- Branch selection errors
- Clock synchronization issues between commits

**Solutions**:

- Standardize commit message templates
- Verify Change-Id integrity in Gerrit
- Double-check branch selection during script execution
- Use `git log --oneline --graph` for visual commit verification

### **Issue**: Missing commits for known tickets

**Possible Causes**:

- Typos in ticket numbers
- Different formatting conventions (e.g., "JIRA-123" vs "TICKET-123")
- Commits in different repositories
- Merge commits being excluded (by design)

**Solutions**:

- Verify exact ticket formatting in repository
- Check related repositories for cross-cutting changes
- Use `git log --grep="partial-ticket-id"` for broader searches

### **Issue**: Incorrect baseline or release branch selection

**Possible Causes**:

- Confusing branch naming conventions
- Incomplete branch synchronization
- Multiple release strategies

**Solutions**:

- Document branch naming conventions clearly
- Use `git branch -a | grep release` to verify available branches
- Confirm branch contents with `git log --oneline -10` before selection

## Advanced Usage Scenarios

### **Multi-Repository Analysis**

For organizations with microservices or multi-repository architectures:

```bash
# Run script across multiple repositories
for repo in service-a service-b service-c; do
    cd $repo
    ./gerrit-report.sh ../shared-tickets.txt > ${repo}-report.md
    cd ..
done
```

### **Automated Integration**

Integration with CI/CD pipelines:

```bash
# Generate report and check for blockers
./gerrit-report.sh tickets.txt > release-report.md

# Extract summary statistics
PARTIAL_COUNT=$(grep "Partially in Production:" release-report.md | grep -o '[0-9]*' | head -1)

if [[ $PARTIAL_COUNT -gt 0 ]]; then
    echo "⚠️  $PARTIAL_COUNT tickets require manual review before release"
    exit 1
fi
```

### **Historical Analysis**

Track deployment patterns over time:

```bash
# Generate reports for previous releases
./gerrit-report.sh tickets-v1.txt > historical/v1-analysis.md
./gerrit-report.sh tickets-v2.txt > historical/v2-analysis.md

# Compare deployment success rates
grep "Release Candidates:" historical/*.md
```

## Conclusion

The Gerrit Ticket Report script transforms complex git history analysis into actionable release management insights. By understanding the detailed ticket lifecycle scenarios and status interpretations provided in this guide, Release Managers can make informed decisions about deployment readiness, identify potential issues early, and maintain high-quality release processes.

The script's strength lies not just in automation, but in providing the detailed context and analysis needed for confident release decisions in complex development environments.
