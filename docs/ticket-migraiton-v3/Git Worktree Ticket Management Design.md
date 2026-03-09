This is a rock-solid choice. By isolating tickets onto an orphan branch and mounting it as a hidden worktree, we completely decouple ticket management from your source code history while keeping it strictly local-first and conflict-free.

Here is the detailed technical design document for the **Dedicated Orphan Branch with Event Sourcing** architecture.

### ---

**1\. Local Architecture & Workflow Integration**

Because your team uses git worktree heavily, our design must ensure all code worktrees share the exact same ticket state in real-time without committing.

We achieve this by having one "master" hidden worktree for tickets, and symlinking it into any new code worktrees you create.

#### **Setup & Teardown Commands**

* **./ticket init (Run once per repository clone):**  
  1. Checks if the tickets branch exists on origin. If not, creates an orphan branch.  
  2. Runs git worktree add .tickets-tracker tickets in the root of your primary clone.  
  3. Adds .tickets-tracker to your global or local .git/info/exclude (so it never shows up in git status).  
* **./ticket worktree-add \<path\> \<branch\> (Replaces standard git worktree add):**  
  1. Runs the standard git worktree add \<path\> \<branch\>.  
  2. Creates a symlink in the new worktree: ln \-s $(pwd)/.tickets-tracker \<path\>/.tickets-tracker.  
     *Result:* Ticket operations in any worktree instantly reflect in all others.  
* **./ticket worktree-remove \<path\>:**  
  1. Unlinks the .tickets-tracker symlink.  
  2. Runs git worktree remove \<path\>.

### **2\. Data Schema (The Append-Only Log)**

Instead of mutable JSON files, every action generates a new file.

**Directory Structure:**

Plaintext

.tickets-tracker/  
  ├── TKT-1/  
  │   ├── 1710000000-abc1-CREATE.json  
  │   ├── 1710000050-def2-STATUS.json  
  │   └── 1710000100-ghi3-COMMENT.json  
  └── TKT-2/  
      └── 1710000200-jkl4-CREATE.json

**Event Schemas:**

All files share a base schema structure, minimizing parsing logic.

| Event Type | File Naming Convention | JSON Payload Structure |
| :---- | :---- | :---- |
| **CREATE** | \<unix\_ts\>-\<uuid\>-CREATE.json | \`{"type": "CREATE", "author": "dev1", "data": {"type": "bug |
| **STATUS** | \<unix\_ts\>-\<uuid\>-STATUS.json | \`{"type": "STATUS", "author": "dev1", "data": {"status": "open |
| **COMMENT** | \<unix\_ts\>-\<comment\_uuid\>-COMMENT.json | {"type": "COMMENT", "author": "dev1", "data": {"text": "..."}} |
| **JIRA\_SYNC** | \<unix\_ts\>-\<uuid\>-SYNC.json | {"type": "SYNC", "author": "system", "data": {"jira\_id": "JIRA-123", "jira\_comment\_ids": {"\<local\_uuid\>": "JIRA-COM-1"}}} |

### **3\. Core Logic: State Reduction via jq**

Since there is no "current state" file, we calculate it on the fly. When a user runs ./ticket show TKT-1, the script does the following:

1. **Read:** cat .tickets-tracker/TKT-1/\*.json  
2. **Reduce (using jq):** We pass the stream of JSON events through a jq reducer script. It processes them in timestamp order:  
   * If CREATE: Initialize the JSON object.  
   * If STATUS: Update .status.  
   * If COMMENT: Append to the .comments array.  
   * If SYNC: Inject the Jira mapping IDs into the ticket and corresponding comments.  
3. **Output:** \* Default: Pretty-printed UI for humans.  
   * LLM Mode (--format=llm): Minified JSON or a dense, token-optimized bulleted list.

*Performance Note (Req \#15):* File reads and a single jq execution take milliseconds. This will not add wall-clock time to your workflow.

### **4\. Git Push/Pull & Conflict Resolution**

Because of the append-only schema, we completely bypass standard Git textual merge conflicts (Req \#11).

* **./ticket sync (Manual or Hook-driven):**  
  1. cd .tickets-tracker  
  2. git pull origin tickets \--rebase  
  3. git push origin tickets  
* **Conflict Handling:** If Developer A and Developer B both comment on TKT-1 offline and push, Git simply downloads both distinct JSON files into the TKT-1/ directory. The jq reducer will automatically sort them by their Unix timestamp when displaying the ticket. No data is lost; no manual merge resolution is required.

### **5\. GitHub Actions & ACLI Jira Sync**

To minimize local dependencies (Req \#10), the Jira integration lives entirely in GitHub Actions.

1. **Trigger:** A workflow triggers on push to the tickets branch.  
2. **Diff Checking:** The action runs git diff \--name-only HEAD^ HEAD to find newly added event files.  
3. **ACLI Execution:** \* If a CREATE event is found, it uses Atlassian CLI (ACLI) to create a Jira issue.  
   * If a STATUS or COMMENT event is found, it pushes that update to the mapped Jira ID.  
4. **Write-Back:** The Action generates a SYNC event JSON file containing the new Jira IDs, commits it to the tickets branch, and pushes it back. The developer will get this sync file locally the next time they run ./ticket sync.

### **6\. Dependency Tracking & Parent-Child Relationships**

* **Parent-Child (Req \#4):** Handled locally via the parent\_id field in the CREATE event. When rendering an Epic, the CLI can run a quick grep across the .tickets-tracker directory to find all tickets claiming it as a parent.  
* **Dependencies (Req \#5):** Handled via a specific LINK event type (e.g., {"type": "LINK", "data": {"blocks": "TKT-5"}}).

### ---

**Next Step**

This architecture gives you Jira syncing, zero local conflicts, and total LLM compatibility without cluttering your code commits.

Would you like me to write the actual **jq reduction script** that compiles the raw event files into the final ticket state, or should we start by writing the **./ticket init Bash script** to handle the worktree/symlink setup?