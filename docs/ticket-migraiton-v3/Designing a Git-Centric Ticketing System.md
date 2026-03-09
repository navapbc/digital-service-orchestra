This is a fascinating engineering challenge. You are looking for a decentralized, local-first ticketing system that sits entirely within your Git ecosystem, survives the chaos of distributed version control without data loss, and acts as a single source of truth that can reliably sync with Atlassian Jira via ACLI.

To meet your requirements—especially the constraints around **real-time local worktree sync (\#8)**, **zero interference with standard git workflows (\#9)**, and **flawless conflict handling (\#11)**—we need to look beyond just storing mutable JSON files in the main branch. If two developers edit the same JSON file and push, you will get merge conflicts that risk data loss. Furthermore, standard working directory files do not sync in real-time across different git worktrees in the same local environment.

To solve this, all three proposed solutions rely on a core design pattern: **Event Sourcing (Append-Only Log)**. Instead of modifying a single ticket.json file, every action (create, change status, add comment) writes a new, unique, timestamped event file. A lightweight read-script compiles these events into the current ticket state on the fly. This completely eliminates Git merge conflicts.

All solutions rely strictly on **bash, git, and jq**, ensuring 100% compatibility with standard GitHub Action runners without requiring you to compile binaries or install heavy dependencies.

Here are 3 architectural solutions to tackle this:

### ---

**Solution 1: Event-Sourced Git Notes / Custom Git Refs (The "Git Object" Approach)**

Instead of storing tickets in your working directory, this solution stores ticket events directly inside Git’s internal object database (.git/objects) and uses a custom reference (e.g., refs/tickets/) to track them.

* **How it works:** When a user types ./ticket create bug "Title", a bash script generates a JSON event, pipes it into git hash-object \-w (saving it to the Git database), and updates a custom reference tree. To read a ticket, the script fetches the blobs from the custom ref and uses jq to reduce the events into a single JSON output.  
* **ACLI Sync:** The script uses an ACLI wrapper. When pulling events, if a Jira sync event is detected, it maps the local UUIDs to Jira IDs.  
* **LLM CLI:** You interact via ./ticket show \<ID\> \--format=llm, which outputs an unformatted, minified JSON string or bulleted list for the LLM to read effortlessly.

**Pros:**

* **Perfect Worktree Sync (Req \#8):** Because all git worktrees on a local machine share the same underlying .git/ folder, a ticket created in Worktree A is instantaneously readable in Worktree B without committing or syncing.  
* **Zero Git Interference (Req \#9):** Tickets do not exist in the working directory. They will never accidentally be included in a git add . or trigger a merge conflict in a standard pull request.  
* **Conflict-Free (Req \#11):** Event sourcing means two developers offline pushing to the same ticket just append two separate blobs to the tree.

**Cons:**

* **Push/Pull Friction:** Developers and CI/CD pipelines must use explicit refspecs to sync tickets (e.g., git fetch origin refs/tickets/\*:refs/tickets/\*). It doesn't happen automatically with a standard git pull.  
* **Script Complexity:** The bash wrapper doing the Git plumbing commands is slightly more complex to maintain than standard file system operations.

### ---

**Solution 2: Dedicated Orphan Branch with a Hidden Worktree**

This solution isolates tickets onto an entirely separate, history-less branch (an "orphan" branch) called tickets.

* **How it works:** A setup script runs git worktree add .tickets-tracker tickets. This mounts the tickets branch into a hidden folder inside your repo. The bash CLI creates append-only JSON event files in this directory: .tickets-tracker/PROJ-1/events/1710001234-comment-uuid.json.  
* **ACLI Sync:** A GitHub Action triggers on pushes to the tickets branch, reading new JSON events, pushing them to Jira via ACLI, and writing a new event back (e.g., jira-sync-uuid.json) to confirm the sync.

**Pros:**

* **Standard Git Operations:** Unlike Solution 1, syncing tickets across environments (Req \#8) uses standard commands: git push origin tickets and git pull origin tickets.  
* **Easy to Debug:** The tickets are just standard files in a hidden directory. You can cd into it and look around.  
* **Conflict-Free & Safe:** The append-only file structure means a git pull on the tickets branch will safely fast-forward and combine files from different environments without textual merge conflicts.

**Cons:**

* **Local Worktree Sync Requires a Symlink:** By default, hidden directories inside a specific worktree aren't shared. To achieve the real-time sync across local worktrees (Req \#8), the init script must symlink the .tickets-tracker folder across your worktrees.  
* **Requires Initial Setup:** Developers must run ./ticket init once when cloning the repo to set up the orphan branch mapping.

### ---

**Solution 3: In-Tree Event Sourcing (The "Submodule / Dedicated Directory" Approach)**

This is the simplest, most brute-force approach. You maintain a .tickets/ directory directly in your main working branch, alongside your source code.

* **How it works:** Just like Solution 2, it uses event-sourced JSON files to avoid conflicts, but they live in .tickets/TICK-1/.  
* **ACLI & Dependencies:** Relies purely on bash and jq. A GitHub Action monitors the .tickets/ path for changes and triggers the bidirectional ACLI sync.

**Pros:**

* **Zero Setup Required:** It works entirely out of the box. No hidden worktrees, no custom git references, and no symlinks. It completely satisfies the constraint to minimize dependencies and brittleness (Req \#10, \#12).  
* **Preserved State:** The exact state of the tickets at the time a code commit was made is perfectly preserved in the git history, making time-travel debugging easy (Req \#1).

**Cons:**

* **Fails Real-Time Local Sync (Req \#8):** Because it is tied to the standard working tree, a change in Worktree A is not visible in Worktree B until it is committed and merged.  
* **Git Workflow Interference (Req \#9):** Ticket operations (like adding a comment) result in standard file changes. They will show up in git status, requiring the developer to commit them. This can clutter pull requests with ticket-metadata commits.

### ---

**Recommendation**

Given your strict constraints, **Solution 2 (Dedicated Orphan Branch with Event Sourcing)** is the most balanced approach.

It keeps your standard code commits completely clean (Req \#9), uses standard bash/jq so it runs natively in GitHub Actions (Req \#10), prevents data loss through event-sourcing (Req \#11), handles your scale of \~200 tickets effortlessly (Req \#13), and isolates the ticket state while keeping it inside the repo. We can easily write a CLI script that outputs minified data optimized for your LLM tooling.

Would you like me to draft the Bash schema and the jq logic required to compile an append-only event stream into a standardized ticket state for Solution 2?