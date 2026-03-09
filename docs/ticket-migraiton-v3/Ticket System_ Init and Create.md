Here are the Bash scripts for initializing the ticketing system and creating new tickets.

To ensure we strictly meet **Requirement \#11 (Gracefully handle conflicts)** and **Requirement \#12 (Not brittle)**, I have designed the local ticket IDs to use a short, random identifier (e.g., TKT-a1b2c3d4). If we used sequential IDs locally (like TKT-1, TKT-2), two developers creating tickets offline at the same time would create a directory collision that our jq reducer would improperly merge. The Jira ID (e.g., PROJ-123) will be injected later by the ACLI sync.

### **1\. The Setup: ./ticket init**

This command is run exactly once after cloning the main repository. It sets up the orphan branch, mounts it to the hidden directory, and ensures it never pollutes your git status.

Bash

\#\!/bin/bash  
\# Usage: ./ticket init

TRACKER\_DIR=".tickets-tracker"  
BRANCH\_NAME="tickets"

echo "Initializing local ticketing system..."

\# 1\. Prevent standard Git from tracking the hidden folder (Req \#9)  
if \! grep \-q "^$TRACKER\_DIR$" .git/info/exclude 2\>/dev/null; then  
  echo "$TRACKER\_DIR" \>\> .git/info/exclude  
fi

\# 2\. Check if the directory already exists  
if \[ \-d "$TRACKER\_DIR" \]; then  
  echo "Tickets tracker is already initialized in $TRACKER\_DIR."  
  exit 0  
fi

\# 3\. Create or checkout the orphan branch  
if git ls-remote \--heads origin $BRANCH\_NAME | grep \-q $BRANCH\_NAME; then  
  \# Branch exists on remote, fetch and mount it  
  git fetch origin $BRANCH\_NAME  
  git worktree add "$TRACKER\_DIR" $BRANCH\_NAME  
else  
  \# First time setup for the whole team: create empty orphan branch  
  git worktree add \--orphan "$TRACKER\_DIR" $BRANCH\_NAME  
    
  \# Initialize with a dummy file so the branch can be pushed  
  cd "$TRACKER\_DIR" || exit  
  echo "Ticket tracking initialized." \> README.md  
  git add README.md  
  git commit \-m "chore: initialize ticket tracker"  
  cd ..  
fi

echo "Success\! The ticketing system is ready."

*(Note: If a developer uses git worktree add to create a new code environment, they just run ln \-s $(pwd)/.tickets-tracker ../\<new-worktree-path\>/.tickets-tracker to instantly share the ticket state across worktrees).*

### ---

**2\. Writing Data: ./ticket create**

This script generates the append-only CREATE event file. It strictly enforces the 4 allowed ticket types and automatically commits the new event into the hidden worktree so it is ready to be pushed.

Bash

\#\!/bin/bash  
\# Usage: ./ticket create \<type\> \<title\> \[parent\_id\]  
\# Example: ./ticket create bug "Login page crashes on mobile"

TRACKER\_DIR=".tickets-tracker"  
TYPE=$1  
TITLE=$2  
PARENT\_ID=${3:-null}

\# 1\. Validate inputs (Req \#6)  
if \[\[ \! "$TYPE" \=\~ ^(bug|epic|story|task)$ \]\]; then  
  echo "Error: Ticket type must be 'bug', 'epic', 'story', or 'task'." \>&2  
  exit 1  
fi

if \[ \-z "$TITLE" \]; then  
  echo "Error: Title is required." \>&2  
  echo "Usage: ./ticket create \<type\> \<title\> \[parent\_id\]" \>&2  
  exit 1  
fi

\# 2\. Generate unique identifiers to prevent offline collisions  
\# Using a cross-platform approach for UUID generation (fallback to urandom)  
if command \-v uuidgen \>/dev/null 2\>&1; then  
  UUID=$(uuidgen | tr '\[:upper:\]' '\[:lower:\]')  
else  
  UUID=$(cat /proc/sys/kernel/random/uuid)  
fi

SHORT\_UUID=${UUID:0:8}  
TICKET\_ID="TKT-$SHORT\_UUID"  
TIMESTAMP=$(date \+%s)  
AUTHOR=$(git config user.name)

\# 3\. Create the ticket directory  
TICKET\_DIR="$TRACKER\_DIR/$TICKET\_ID"  
mkdir \-p "$TICKET\_DIR"

\# 4\. Construct the CREATE event payload  
EVENT\_FILE="$TICKET\_DIR/$TIMESTAMP\-$UUID\-CREATE.json"

cat \<\<EOF \> "$EVENT\_FILE"  
{  
  "timestamp": $TIMESTAMP,  
  "uuid": "$UUID",  
  "type": "CREATE",  
  "author": "$AUTHOR",  
  "data": {  
    "ticket\_type": "$TYPE",  
    "title": "$TITLE",  
    "parent\_id": $(if \[ "$PARENT\_ID" \== "null" \]; then echo "null"; else echo "\\"$PARENT\_ID\\""; fi)  
  }  
}  
EOF

\# 5\. Automatically commit the event in the hidden worktree  
cd "$TRACKER\_DIR" || exit  
git add "$TICKET\_ID/"  
git commit \-m "ticket: create $TICKET\_ID ($TYPE)" \>/dev/null  
cd ..

\# 6\. LLM / CLI Output (Req \#14)  
\# If we want standard output, we just echo.   
\# For scripts/LLMs, printing just the ID is often best so it can be captured into a variable.  
echo "$TICKET\_ID"

### **How this fits the workflow:**

1. A developer notices a bug while working in their local worktree.  
2. They run ./ticket create bug "Null pointer in auth service".  
3. The script outputs TKT-a1b2c3d4.  
4. The JSON file is written to .tickets-tracker/TKT-a1b2c3d4/...-CREATE.json and committed to the tickets branch in the background.  
5. Their standard working directory (git status) remains completely clean. They continue coding without interruption.  
6. Whenever they are ready, they run ./ticket sync (which just does a git pull \--rebase and git push inside the .tickets-tracker folder).

### ---

**Next Step**

We have the core local components drafted: the setup, the read-reducer (jq), and the write-creator (bash).

The final crucial piece of this puzzle is the bridge to Atlassian Jira. Would you like me to draft the **GitHub Actions workflow YAML** and the associated script that watches this orphan branch, triggers the **ACLI bidirectional sync**, and writes the SYNC events back to the repository?