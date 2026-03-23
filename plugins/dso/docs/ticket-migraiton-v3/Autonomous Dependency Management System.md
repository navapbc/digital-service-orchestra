Managing dependencies autonomously is where an agentic workflow truly shines. Instead of a human project manager constantly checking Jira to tell an engineer they are unblocked, the agent can query the system, recognize a path is clear, and immediately begin its TDD cycle on the newly unblocked ticket.

To solve Requirement \#5 without making the system brittle or adding external databases, we will rely on **directed edge events** in our append-only log, and use jq to traverse the graph on the fly. With only \~200 open tickets, a full graph traversal in jq will take less than 50 milliseconds.

Here is the design for the dependency tracking engine and how an agent interacts with it.

### **1\. Writing Dependencies (ticket link)**

We need a command that allows either a human or an agent to define a relationship.

**Command:**

Bash

ticket link \<source\_id\> \<relation\> \<target\_id\>  
# Example: ticket link TKT-a1b2c3d4 blocks TKT-f5g4h3j2

**Bash Implementation (ticket link):**

This script generates a LINK event and drops it into the source ticket's directory.

Bash

\#\!/bin/bash  
\# Usage: ticket link \<source\_id\> \<relation\> \<target\_id\>

TRACKER\_DIR=".tickets-tracker"  
SOURCE\_ID=$1  
RELATION=$2   \# e.g., "blocks", "depends\_on", "relates\_to"  
TARGET\_ID=$3

\# 1\. Validation (ensure both tickets exist)  
if \[ \! \-d "$TRACKER\_DIR/$SOURCE\_ID" \] || \[ \! \-d "$TRACKER\_DIR/$TARGET\_ID" \]; then  
  echo '{"error": "One or both tickets do not exist."}'  
  exit 1  
fi

\# 2\. Generate Event Metadata  
TIMESTAMP=$(date \+%s)  
UUID=$(cat /proc/sys/kernel/random/uuid | cut \-d'-' \-f1)  
EVENT\_FILE="$TRACKER\_DIR/$SOURCE\_ID/$TIMESTAMP\-$UUID\-LINK.json"

\# 3\. Write Append-Only Event  
cat \<\<EOF \> "$EVENT\_FILE"  
{  
  "timestamp": $TIMESTAMP,  
  "type": "LINK",  
  "author": "$(git config user.name)",  
  "data": {  
    "relation": "$RELATION",  
    "target": "$TARGET\_ID"  
  }  
}  
EOF

\# 4\. Commit silently  
cd "$TRACKER\_DIR" || exit  
git add "$SOURCE\_ID/"  
git commit \-m "ticket: $SOURCE\_ID $RELATION $TARGET\_ID" \>/dev/null  
cd ..

\# 5\. Output for LLM  
echo '{"status":"success","action":"link","source":"'"$SOURCE\_ID"'","target":"'"$TARGET\_ID"'"}'

### **2\. Reading the Graph (ticket deps)**

When an agent wants to know if a ticket is ready to be worked on, it needs to know if any of its depends\_on targets are still in an "open" or "in progress" state.

Because jq is incredibly fast, we can compile the entire state of all \~200 open tickets in memory and evaluate the graph in a single command.

**Command:**

Bash

ticket deps TKT-f5g4h3j2 \--format=llm

**The Graph Resolution Script (ticket deps):**

This script compiles all tickets, finds the requested ticket, and evaluates its blockers.

Bash

\#\!/bin/bash  
# Usage: ticket deps \<ticket\_id\> \[--format=llm\]

TARGET\_TICKET=$1  
FORMAT=$2

\# Compile ALL tickets into a single JSON array on the fly  
\# (In practice, you might cache this compiled state locally for   
\# a few seconds, but for 200 tickets, real-time is fine).  
ALL\_TICKETS=$(  
  for dir in .tickets-tracker/TKT-\*; do  
    cat "$dir"/\*.json  
  done | jq \-s '  
    \# (Simplified reducer logic from our earlier script here)  
    group\_by(.data.local\_id) | map(...)   
  '  
)

\# Use jq to find tickets blocking the target  
echo "$ALL\_TICKETS" | jq \-c '  
  \# Find the target ticket  
  (.\[\] | select(.id \== "'"$TARGET\_TICKET"'")) as $target |  
    
  \# Find all tickets where this target is listed in their dependencies   
  \# with a "blocks" relation, OR tickets that the target explicitly "depends\_on".  
  \[ .\[\] | select(  
    (.dependencies\[\]? | select(.relation \== "blocks" and .target \== $target.id)) or  
    ($target.dependencies\[\]? | select(.relation \== "depends\_on" and .target \== .id))  
  ) \] |   
    
  \# Map the output to show if the blockers are still active  
  map({  
    id: .id,  
    title: .title,  
    status: .status,  
    is\_blocking: (.status \!= "closed")  
  }) |   
    
  \# Final LLM Output Structure  
  {  
    ticket: $target.id,  
    ready\_to\_work: (map(.is\_blocking) | any | not),  
    blockers: .  
  }  
'

**LLM-Optimized Output:**

JSON

{"ticket":"TKT-f5g4h3j2","ready\_to\_work":false,"blockers":\[{"id":"TKT-a1b2c3d4","title":"Null pointer in auth service","status":"in progress","is\_blocking":true}\]}

*Agent Logic:* The agent reads "ready\_to\_work": false and autonomously decides to skip this ticket and query the backlog for a different task.

### **3\. The Autonomous "Unblock" Trigger**

To make the system fully autonomous, we modify the ticket transition command we built earlier.

When an agent finishes its HCD review cycle or passing TDD tests, it runs ticket transition TKT-a1b2c3d4 closed.

Inside the ticket transition script, we add a post-transition hook:

1. State changes to closed.  
2. The script quietly runs a reverse-lookup on the graph: *Did TKT-a1b2c3d4 block anything else?*  
3. If yes, it checks those target tickets. If all *their* blockers are now closed, the CLI output includes a specific trigger for the LLM.

**Command:**

Bash

ticket transition TKT-a1b2c3d4 closed \--format=llm

**LLM-Optimized Output (with trigger):**

JSON

{"status":"success","id":"TKT-a1b2c3d4","new\_state":"closed","events":\[{"type":"UNBLOCKED","target\_id":"TKT-f5g4h3j2","title":"Missing error boundary on dashboard"}\]}

By returning the UNBLOCKED event directly in the transition output, the agent doesn't have to poll the system or guess what to do next. It immediately parses target\_id, loads TKT-f5g4h3j2, and starts its next loop.

### ---

**Next Step**

We now have a complete lifecycle: isolated local storage, Jira sync via GitHub actions, LLM-optimized state output, and autonomous dependency resolution.

To wrap up this technical design document, would you like me to outline the **Parent-Child Hierarchy logic (Requirement \#4)** (e.g., how an Epic calculates its completion percentage based on its child Stories/Tasks), or should we consolidate all these pieces into a final, summarized architectural diagram and implementation plan?