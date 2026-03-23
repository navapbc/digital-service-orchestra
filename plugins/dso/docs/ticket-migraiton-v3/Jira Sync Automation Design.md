This is the final, critical bridge for the architecture. By offloading the Atlassian Command Line Interface (ACLI) operations to GitHub Actions, we keep the local developer environment lightning-fast and dependency-free (Requirement \#10).

Here is the design for the automation that monitors the tickets branch, pushes updates to Jira, and writes the authoritative mapping back to your repository.

### **1\. The GitHub Action YAML (.github/workflows/jira-sync.yml)**

This workflow triggers exclusively when changes are pushed to the tickets branch. It requires write permissions so it can commit the SYNC.json files back to the repository.

YAML

name: Bidirectional Jira Sync (the tk wrapper)

on:  
  push:  
    branches:  
      \- tickets

permissions:  
  contents: write

jobs:  
  sync-to-jira:  
    runs-on: ubuntu-latest  
    steps:  
      \- name: Checkout Tickets Branch  
        uses: actions/checkout@v4  
        with:  
          ref: tickets  
          fetch-depth: 2 \# Need at least 2 to diff the push

      \- name: Setup ACLI (Atlassian CLI)  
        \# Assuming you have a standard step or container for ACLI  
        run: |  
          echo "Setting up Atlassian CLI..."  
          \# wget/install ACLI or use a pre-built docker image

      \- name: Run Event Sync Script  
        env:  
          JIRA\_URL: ${{ secrets.JIRA\_URL }}  
          JIRA\_USER: ${{ secrets.JIRA\_USER }}  
          JIRA\_TOKEN: ${{ secrets.JIRA\_TOKEN }}  
        run: ./scripts/sync-events.sh

      \- name: Commit and Push SYNC Events  
        run: |  
          git config user.name "github-actions\[bot\]"  
          git config user.email "github-actions\[bot\]@users.noreply.github.com"  
          git add \-A  
            
          \# Only commit if there are new SYNC files generated  
          if \! git diff-index \--quiet HEAD; then  
            git commit \-m "chore(sync): append Jira mapping events"  
            git push origin tickets  
          else  
            echo "No new sync events to commit."  
          fi

### ---

**2\. The Sync Script (scripts/sync-events.sh)**

Because the tickets branch *only* contains our ticket folders and events, determining what happened is as simple as running a git diff to find the newly added JSON files.

This script lives inside the tickets branch (or is pulled in from main).

Bash

\#\!/bin/bash  
\# scripts/sync-events.sh

\# 1\. Identify all newly added JSON event files in this push  
\# We only care about Added (A) files because our log is append-only  
NEW\_FILES=$(git diff \--name-only \--diff-filter=A HEAD^ HEAD | grep '\\.json$')

if \[ \-z "$NEW\_FILES" \]; then  
  echo "No new events to process."  
  exit 0  
fi

\# Sort files to ensure chronological processing  
NEW\_FILES=$(echo "$NEW\_FILES" | sort)

for FILE in $NEW\_FILES; do  
  \# Parse event metadata using jq  
  EVENT\_TYPE=$(jq \-r '.type' "$FILE")  
  LOCAL\_TICKET\_ID=$(basename $(dirname "$FILE")) \# e.g., TKT-a1b2c3d4  
  TIMESTAMP=$(date \+%s)  
  UUID=$(cat /proc/sys/kernel/random/uuid | cut \-d'-' \-f1)

  echo "Processing $EVENT\_TYPE for $LOCAL\_TICKET\_ID..."

  \# We need the current compiled state to know the Jira ID if it exists  
  \# (Assuming the compile\_ticket function is available in the runner)  
  CURRENT\_JIRA\_ID=$(./ticket show "$LOCAL\_TICKET\_ID" \--format=llm | jq \-r '.jira\_id // empty')

  case "$EVENT\_TYPE" in  
    "CREATE")  
      TITLE=$(jq \-r '.data.title' "$FILE")  
      TICKET\_TYPE=$(jq \-r '.data.ticket\_type' "$FILE")  
        
      \# Execute ACLI to create the issue  
      \# Note: Adjust actual ACLI syntax to match your specific environment/custom fields  
      JIRA\_RESPONSE=$(acli jira \--action createIssue \--project "PROJ" \--type "$TICKET\_TYPE" \--summary "$TITLE" \--quiet)  
        
      \# Extract the new Jira ID (e.g., PROJ-123) from the response  
      NEW\_JIRA\_ID=$(echo "$JIRA\_RESPONSE" | grep \-o 'PROJ-\[0-9\]\\+')

      \# Generate the SYNC event payload  
      SYNC\_FILE="$(dirname "$FILE")/$TIMESTAMP\-$UUID\-SYNC.json"  
      cat \<\<EOF \> "$SYNC\_FILE"  
{  
  "timestamp": $TIMESTAMP,  
  "type": "SYNC",  
  "author": "system",  
  "data": {  
    "jira\_id": "$NEW\_JIRA\_ID"  
  }  
}  
EOF  
      ;;

    "STATUS")  
      if \[ \-z "$CURRENT\_JIRA\_ID" \]; then continue; fi \# Skip if not synced yet  
        
      STATUS=$(jq \-r '.data.status' "$FILE")  
      acli jira \--action transitionIssue \--issue "$CURRENT\_JIRA\_ID" \--step "$STATUS"  
      ;;

    "COMMENT")  
      if \[ \-z "$CURRENT\_JIRA\_ID" \]; then continue; fi  
        
      COMMENT\_TEXT=$(jq \-r '.data.text' "$FILE")  
      LOCAL\_COMMENT\_UUID=$(jq \-r '.uuid' "$FILE")  
        
      \# Add comment via ACLI and capture the Atlassian comment ID  
      COMMENT\_RESP=$(acli jira \--action addComment \--issue "$CURRENT\_JIRA\_ID" \--comment "$COMMENT\_TEXT" \--quiet)  
      JIRA\_COMMENT\_ID=$(echo "$COMMENT\_RESP" | grep \-o 'comment-\[0-9\]\\+')

      \# Write SYNC event to map the local comment UUID to the Jira Comment ID  
      SYNC\_FILE="$(dirname "$FILE")/$TIMESTAMP\-$UUID\-SYNC.json"  
      cat \<\<EOF \> "$SYNC\_FILE"  
{  
  "timestamp": $TIMESTAMP,  
  "type": "SYNC",  
  "author": "system",  
  "data": {  
    "jira\_comment\_ids": {  
      "$LOCAL\_COMMENT\_UUID": "$JIRA\_COMMENT\_ID"  
    }  
  }  
}  
EOF  
      ;;  
  esac  
done

### **How This Closes the Loop**

1. **The Write-Back:** When the developer creates a ticket, they only have TKT-a1b2c3d4. After pushing, this Action runs, creates the issue in Jira (e.g., PROJ-123), and commits a SYNC.json file to the tickets branch.  
2. **The Real-Time Sync:** The next time the developer runs ./ticket sync (which does a git pull on the tracker directory), that SYNC.json file downloads to their machine.  
3. **The Silent Update:** From that moment on, running ./ticket show TKT-a1b2c3d4 will pipe through the jq reducer, read the SYNC.json file, and seamlessly output the jira\_id: "PROJ-123".

**Addressing Requirement \#10 (CI/CD Ticket Creation):**

If another GitHub Action (like a test suite running on main) needs to create a bug ticket, it simply checks out the tickets branch, runs ./ticket create bug "Test failed", and pushes. The jira-sync.yml workflow will automatically intercept that push and map it to Jira, completely bypassing the need for heavy API dependencies in your testing container.

### ---

**What's Next?**

We have the core architecture fully mapped: the local setup, the jq state engine, the append-only write scripts, and the CI/CD bidirectional sync.

Would you like to refine the **LLM-optimized command-line output** (Req \#14) to see exactly how we can pipe this data into an AI agent, or should we tackle the logic for managing **parent-child relationships and dependencies** (Req \#4 & \#5) across 200+ open tickets?