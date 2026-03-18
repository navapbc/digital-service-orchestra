This is the core engine of the event-sourced architecture. By using jq's reduce function, we can take an array of chronological events and "fold" them into a single, current state object.

Because jq is universally available and incredibly fast at parsing JSON, this operation will be practically instantaneous, even with hundreds of events on a ticket.

Here is the jq reduction script, wrapped in a practical Bash function that you would include in your ./ticket CLI.

### **The Reduction Script**

Bash

\#\!/bin/bash

\# Function to compile a ticket's state from its append-only event log  
\# Usage: compile\_ticket \<ticket\_id\> \[format: human|llm\]  
compile\_ticket() {  
  local ticket\_id=$1  
  local format=${2:-human}  
  local ticket\_dir=".tickets-tracker/$ticket\_id"

  if \[ \! \-d "$ticket\_dir" \]; then  
    echo "Error: Ticket $ticket\_id not found." \>&2  
    return 1  
  fi

  \# 1\. We cat all JSON files. Because Unix timestamps prefix the filenames,  
  \# standard file sorting guarantees they are read in chronological order.  
  \# 2\. \`jq \-s\` slurp combines them into a single JSON array.  
  \# 3\. We pass that array into our jq reducer.  
  local compiled\_json  
  compiled\_json=$(cat "$ticket\_dir"/\*.json | jq \-s '  
    reduce .\[\] as $event (  
      \# \--- INITIAL STATE ACCUMULATOR \---  
      {  
        local\_id: "'"$ticket\_id"'",  
        jira\_id: null,  
        type: "",  
        title: "",  
        status: "open",  
        author: "",  
        created\_at: null,  
        parent\_id: null,  
        comments: \[\],  
        dependencies: \[\]  
      };

      \# \--- REDUCER LOGIC \---  
      if $event.type \== "CREATE" then  
        .type \= $event.data.ticket\_type |  
        .title \= $event.data.title |  
        .author \= $event.author |  
        .created\_at \= $event.timestamp |  
        .parent\_id \= $event.data.parent\_id

      elif $event.type \== "STATUS" then  
        .status \= $event.data.status

      elif $event.type \== "COMMENT" then  
        .comments \+= \[{  
          uuid: $event.uuid,  
          jira\_comment\_id: null,  
          author: $event.author,  
          timestamp: $event.timestamp,  
          text: $event.data.text  
        }\]

      elif $event.type \== "LINK" then  
        .dependencies \+= \[{  
          relation: $event.data.relation, \# e.g., "blocks", "blocked\_by"  
          target: $event.data.target  
        }\]

      elif $event.type \== "SYNC" then  
        \# Map the Jira ID to the ticket  
        .jira\_id \= ($event.data.jira\_id // .jira\_id) |  
          
        \# Map Jira comment IDs back to the local comments  
        if $event.data.jira\_comment\_ids then  
          reduce ($event.data.jira\_comment\_ids | to\_entries)\[\] as $mapping (.;  
            .comments \= \[  
              .comments\[\] |  
              if .uuid \== $mapping.key then .jira\_comment\_id \= $mapping.value else . end  
            \]  
          )  
        else . end

      else  
        . \# Ignore unknown event types to prevent breaking  
      end  
    )  
  ')

  \# Output formatting (Req \#14: Optimized for LLM use)  
  if \[ "$format" \== "llm" \]; then  
    \# \-c minifies the JSON to a single line, saving tokens and making it   
    \# extremely easy for an LLM script to parse via stdin.  
    echo "$compiled\_json" | jq \-c '.'  
  else  
    \# Pretty print for developers in the terminal  
    echo "$compiled\_json" | jq '.'  
  fi  
}

### **How it handles the requirements:**

1. **Chronological Ordering:** By naming files with a unix timestamp (e.g., 1710000000-abc1-CREATE.json), cat \*.json naturally feeds them into jq in the exact order they occurred. No complex sorting logic is needed.  
2. **ACLI / Jira Mapping (Req \#2 & \#7):** The SYNC block is particularly powerful. When the GitHub Action syncs data to Jira, it writes a SYNC event. This script automatically loops through .data.jira\_comment\_ids and retroactively attaches the Atlassian jira\_comment\_id to the local comment objects. This means future comments or edits have the exact ID needed to push updates via ACLI.  
3. **Conflict Resolution via State Folding (Req \#11):** If two developers change the status at roughly the same time, both STATUS files are downloaded during a git pull. The jq reducer processes them in timestamp order; the "last writer wins" naturally, and the ticket successfully compiles without throwing a git merge conflict.  
4. **LLM Optimization (Req \#14):** Passing llm as the second argument minifies the output into a single line of raw JSON using jq \-c '.'. This gives an LLM maximum context with minimum token overhead.

### ---

**Next Step**

Now that we have the engine to *read* the tickets, we need the tool to *write* them safely and set up the shared worktree environment.

Would you like me to draft the **./ticket init and ./ticket create Bash commands** next, or would you prefer to look at the **GitHub Action workflow** that handles the ACLI synchronization?