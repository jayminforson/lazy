//
//  BundledSkills+Hermes.swift
//  Clicky
//
//  M4 B2 — GENERATED one-time data: the 25 hermes-agent root skill docs
//  (vendored verbatim, MIT © Nous Research 2025 — see NOTICE.md). Do not
//  hand-edit; regenerate only from the heyref snapshot if ever needed.
//

extension BundledSkills {
    static let bundledHermesEntries: [Entry] = [
        Entry(
            name: "airtable",
            description: "Airtable REST API via curl. Records CRUD, filters, upserts.",
            body: #"""
            ---
            name: airtable
            description: Airtable REST API via curl. Records CRUD, filters, upserts.
            version: 1.1.0
            author: community
            license: MIT
            prerequisites:
              env_vars: [AIRTABLE_API_KEY]
              commands: [curl]
            metadata:
              hermes:
                tags: [Airtable, Productivity, Database, API]
                homepage: https://airtable.com/developers/web/api/introduction
            ---

            # Airtable — Bases, Tables & Records

            Work with Airtable's REST API directly via `curl` using the `terminal` tool. No MCP server, no OAuth flow, no Python SDK — just `curl` and a personal access token.

            ## Prerequisites

            1. Create a **Personal Access Token (PAT)** at https://airtable.com/create/tokens (tokens start with `pat...`).
            2. Grant these scopes (minimum):
               - `data.records:read` — read rows
               - `data.records:write` — create / update / delete rows
               - `schema.bases:read` — list bases and tables
            3. **Important:** in the same token UI, add each base you want to access to the token's **Access** list. PATs are scoped per-base — a valid token on the wrong base returns `403`.
            4. Store the token in `~/.hermes/.env` (or via `hermes setup`):
               ```
               AIRTABLE_API_KEY=pat_your_token_here
               ```

            > Note: legacy `key...` API keys were deprecated Feb 2024. Only PATs and OAuth tokens work now.

            ## API Basics

            - **Endpoint:** `https://api.airtable.com/v0`
            - **Auth header:** `Authorization: Bearer $AIRTABLE_API_KEY`
            - **All requests** use JSON (`Content-Type: application/json` for any POST/PATCH/PUT body).
            - **Object IDs:** bases `app...`, tables `tbl...`, records `rec...`, fields `fld...`. IDs never change; names can. Prefer IDs in automations.
            - **Rate limit:** 5 requests/sec/base. `429` → back off. Burst on a single base will be throttled.

            Base curl pattern:
            ```bash
            curl -s "https://api.airtable.com/v0/$BASE_ID/$TABLE?maxRecords=5" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```

            `-s` suppresses curl's progress bar — keep it set for every call so the tool output stays clean for Hermes. Pipe through `python3 -m json.tool` (always present) or `jq` (if installed) for readable JSON.

            ## Field Types (request body shapes)

            | Field type | Write shape |
            |---|---|
            | Single line text | `"Name": "hello"` |
            | Long text | `"Notes": "multi\nline"` |
            | Number | `"Score": 42` |
            | Checkbox | `"Done": true` |
            | Single select | `"Status": "Todo"` (name must already exist unless `typecast: true`) |
            | Multi-select | `"Tags": ["urgent", "bug"]` |
            | Date | `"Due": "2026-04-01"` |
            | DateTime (UTC) | `"At": "2026-04-01T14:30:00.000Z"` |
            | URL / Email / Phone | `"Link": "https://…"` |
            | Attachment | `"Files": [{"url": "https://…"}]` (Airtable fetches + rehosts) |
            | Linked record | `"Owner": ["recXXXXXXXXXXXXXX"]` (array of record IDs) |
            | User | `"AssignedTo": {"id": "usrXXXXXXXXXXXXXX"}` |

            Pass `"typecast": true` at the top level of a create/update body to let Airtable auto-coerce values (e.g. create a new select option on the fly, convert `"42"` → `42`).

            ## Common Queries

            ### List bases the token can see
            ```bash
            curl -s "https://api.airtable.com/v0/meta/bases" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```

            ### List tables + schema for a base
            ```bash
            curl -s "https://api.airtable.com/v0/meta/bases/$BASE_ID/tables" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```
            Use this BEFORE mutating — confirms exact field names and IDs, surfaces `options.choices` for select fields, and shows primary-field names.

            ### List records (first 10)
            ```bash
            curl -s "https://api.airtable.com/v0/$BASE_ID/$TABLE?maxRecords=10" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```

            ### Get a single record
            ```bash
            curl -s "https://api.airtable.com/v0/$BASE_ID/$TABLE/$RECORD_ID" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```

            ### Filter records (filterByFormula)
            Airtable formulas must be URL-encoded. Let Python stdlib do it — never hand-encode:
            ```bash
            FORMULA="{Status}='Todo'"
            ENC=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$FORMULA")
            curl -s "https://api.airtable.com/v0/$BASE_ID/$TABLE?filterByFormula=$ENC&maxRecords=20" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```

            Useful formula patterns:
            - Exact match: `{Email}='user@example.com'`
            - Contains: `FIND('bug', LOWER({Title}))`
            - Multiple conditions: `AND({Status}='Todo', {Priority}='High')`
            - Or: `OR({Owner}='alice', {Owner}='bob')`
            - Not empty: `NOT({Assignee}='')`
            - Date comparison: `IS_AFTER({Due}, TODAY())`

            ### Sort + select specific fields
            ```bash
            curl -s "https://api.airtable.com/v0/$BASE_ID/$TABLE?sort%5B0%5D%5Bfield%5D=Priority&sort%5B0%5D%5Bdirection%5D=asc&fields%5B%5D=Name&fields%5B%5D=Status" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```
            Square brackets in query params MUST be URL-encoded (`%5B` / `%5D`).

            ### Use a named view
            ```bash
            curl -s "https://api.airtable.com/v0/$BASE_ID/$TABLE?view=Grid%20view&maxRecords=50" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```
            Views apply their saved filter + sort server-side.

            ## Common Mutations

            ### Create a record
            ```bash
            curl -s -X POST "https://api.airtable.com/v0/$BASE_ID/$TABLE" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"fields":{"Name":"New task","Status":"Todo","Priority":"High"}}' | python3 -m json.tool
            ```

            ### Create up to 10 records in one call
            ```bash
            curl -s -X POST "https://api.airtable.com/v0/$BASE_ID/$TABLE" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{
                "typecast": true,
                "records": [
                  {"fields": {"Name": "Task A", "Status": "Todo"}},
                  {"fields": {"Name": "Task B", "Status": "In progress"}}
                ]
              }' | python3 -m json.tool
            ```
            Batch endpoints are capped at **10 records per request**. For larger inserts, loop in batches of 10 with a short sleep to respect 5 req/sec/base.

            ### Update a record (PATCH — merges, preserves unchanged fields)
            ```bash
            curl -s -X PATCH "https://api.airtable.com/v0/$BASE_ID/$TABLE/$RECORD_ID" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"fields":{"Status":"Done"}}' | python3 -m json.tool
            ```

            ### Upsert by a merge field (no ID needed)
            ```bash
            curl -s -X PATCH "https://api.airtable.com/v0/$BASE_ID/$TABLE" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{
                "performUpsert": {"fieldsToMergeOn": ["Email"]},
                "records": [
                  {"fields": {"Email": "user@example.com", "Status": "Active"}}
                ]
              }' | python3 -m json.tool
            ```
            `performUpsert` creates records whose merge-field values are new, patches records whose merge-field values already exist. Great for idempotent syncs.

            ### Delete a record
            ```bash
            curl -s -X DELETE "https://api.airtable.com/v0/$BASE_ID/$TABLE/$RECORD_ID" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```

            ### Delete up to 10 records in one call
            ```bash
            curl -s -X DELETE "https://api.airtable.com/v0/$BASE_ID/$TABLE?records%5B%5D=rec1&records%5B%5D=rec2" \
              -H "Authorization: Bearer $AIRTABLE_API_KEY" | python3 -m json.tool
            ```

            ## Pagination

            List endpoints return at most **100 records per page**. If the response includes `"offset": "..."`, pass it back on the next call. Loop until the field is absent:

            ```bash
            OFFSET=""
            while :; do
              URL="https://api.airtable.com/v0/$BASE_ID/$TABLE?pageSize=100"
              [ -n "$OFFSET" ] && URL="$URL&offset=$OFFSET"
              RESP=$(curl -s "$URL" -H "Authorization: Bearer $AIRTABLE_API_KEY")
              echo "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(r["id"], r["fields"].get("Name","")) for r in d["records"]]'
              OFFSET=$(echo "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("offset",""))')
              [ -z "$OFFSET" ] && break
            done
            ```

            ## Typical Hermes Workflow

            1. **Confirm auth.** `curl -s -o /dev/null -w "%{http_code}\n" https://api.airtable.com/v0/meta/bases -H "Authorization: Bearer $AIRTABLE_API_KEY"` — expect `200`.
            2. **Find the base.** List bases (step above) OR ask the user for the `app...` ID directly if the token lacks `schema.bases:read`.
            3. **Inspect the schema.** `GET /v0/meta/bases/$BASE_ID/tables` — cache the exact field names and primary-field name locally in the session before mutating anything.
            4. **Read before you write.** For "update X where Y", `filterByFormula` first to resolve the `rec...` ID, then `PATCH /v0/$BASE_ID/$TABLE/$RECORD_ID`. Never guess record IDs.
            5. **Batch writes.** Combine related creates into one 10-record POST to stay under the 5 req/sec budget.
            6. **Destructive ops.** Deletions can't be undone via API. If the user says "delete all Xs", echo back the filter + record count and confirm before firing.

            ## Pitfalls

            - **`filterByFormula` MUST be URL-encoded.** Field names with spaces or non-ASCII also need encoding (`{My Field}` → `%7BMy%20Field%7D`). Use Python stdlib (pattern above) — never hand-escape.
            - **Empty fields are omitted from responses.** A missing `"Assignee"` key doesn't mean the field doesn't exist — it means this record's value is empty. Check the schema (step 3) before concluding a field is missing.
            - **PATCH vs PUT.** `PATCH` merges supplied fields into the record. `PUT` replaces the record entirely and clears any field you didn't include. Default to `PATCH`.
            - **Single-select options must exist.** Writing `"Status": "Shipping"` when `Shipping` isn't in the field's option list errors with `INVALID_MULTIPLE_CHOICE_OPTIONS` unless you pass `"typecast": true` (which auto-creates the option).
            - **Per-base token scoping.** A `403` on one base while another works means the token's Access list doesn't include that base — not a scope or auth issue. Send the user to https://airtable.com/create/tokens to grant it.
            - **Rate limits are per base, not per token.** 5 req/sec on `baseA` and 5 req/sec on `baseB` is fine; 6 req/sec on `baseA` alone will throttle. Monitor the `Retry-After` header on `429`.

            ## Important Notes for Hermes

            - **Always use the `terminal` tool with `curl`.** Do NOT use `web_extract` (it can't send auth headers) or `browser_navigate` (needs UI auth and is slow).
            - **`AIRTABLE_API_KEY` flows from `~/.hermes/.env` into the subprocess automatically** when this skill is loaded — no need to re-export it before each `curl` call.
            - **Escape curly braces in formulas carefully.** In a heredoc body, `{Status}` is literal. In a shell argument, `{Status}` is safe outside `{...}` brace-expansion context — but pass dynamic strings through `python3 urllib.parse.quote` before splicing into a URL.
            - **Pretty-print with `python3 -m json.tool`** (always present) rather than `jq` (optional). Only reach for `jq` when you need filtering/projection.
            - **Pagination is per-page, not global.** Airtable's 100-record cap is a hard limit; there is no way to bump it. Loop with `offset` until the field is absent.
            - **Read the `errors` array** on non-2xx responses — Airtable returns structured error codes like `AUTHENTICATION_REQUIRED`, `INVALID_PERMISSIONS`, `MODEL_ID_NOT_FOUND`, `INVALID_MULTIPLE_CHOICE_OPTIONS` that tell you exactly what's wrong.

            """#
        ),
        Entry(
            name: "apple-notes",
            description: "Manage Apple Notes via memo CLI: create, search, edit.",
            body: #"""
            ---
            name: apple-notes
            description: "Manage Apple Notes via memo CLI: create, search, edit."
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            platforms: [macos]
            metadata:
              hermes:
                tags: [Notes, Apple, macOS, note-taking]
                related_skills: [obsidian]
            prerequisites:
              commands: [memo]
            ---

            # Apple Notes

            Use `memo` to manage Apple Notes directly from the terminal. Notes sync across all Apple devices via iCloud.

            ## Prerequisites

            - **macOS** with Notes.app
            - Install: `brew tap antoniorodr/memo && brew install antoniorodr/memo/memo`
            - Grant Automation access to Notes.app when prompted (System Settings → Privacy → Automation)

            ## When to Use

            - User asks to create, view, or search Apple Notes
            - Saving information to Notes.app for cross-device access
            - Organizing notes into folders
            - Exporting notes to Markdown/HTML

            ## When NOT to Use

            - Obsidian vault management → use the `obsidian` skill
            - Bear Notes → separate app (not supported here)
            - Quick agent-only notes → use the `memory` tool instead

            ## Quick Reference

            ### View Notes

            ```bash
            memo notes                        # List all notes
            memo notes -f "Folder Name"       # Filter by folder
            memo notes -s "query"             # Search notes (fuzzy)
            ```

            ### Create Notes

            ```bash
            memo notes -a                     # Interactive editor
            memo notes -a "Note Title"        # Quick add with title
            ```

            ### Edit Notes

            ```bash
            memo notes -e                     # Interactive selection to edit
            ```

            ### Delete Notes

            ```bash
            memo notes -d                     # Interactive selection to delete
            ```

            ### Move Notes

            ```bash
            memo notes -m                     # Move note to folder (interactive)
            ```

            ### Export Notes

            ```bash
            memo notes -ex                    # Export to HTML/Markdown
            ```

            ## Limitations

            - Cannot edit notes containing images or attachments
            - Interactive prompts require terminal access (use pty=true if needed)
            - macOS only — requires Apple Notes.app

            ## Rules

            1. Prefer Apple Notes when user wants cross-device sync (iPhone/iPad/Mac)
            2. Use the `memory` tool for agent-internal notes that don't need to sync
            3. Use the `obsidian` skill for Markdown-native knowledge management

            """#
        ),
        Entry(
            name: "apple-reminders",
            description: "Apple Reminders via remindctl: add, list, complete.",
            body: #"""
            ---
            name: apple-reminders
            description: "Apple Reminders via remindctl: add, list, complete."
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            platforms: [macos]
            metadata:
              hermes:
                tags: [Reminders, tasks, todo, macOS, Apple]
            prerequisites:
              commands: [remindctl]
            ---

            # Apple Reminders

            Use `remindctl` to manage Apple Reminders directly from the terminal. Tasks sync across all Apple devices via iCloud.

            ## Prerequisites

            - **macOS** with Reminders.app
            - Install: `brew install steipete/tap/remindctl`
            - Grant Reminders permission when prompted
            - Check: `remindctl status` / Request: `remindctl authorize`

            ## When to Use

            - User mentions "reminder" or "Reminders app"
            - Creating personal to-dos with due dates that sync to iOS
            - Managing Apple Reminders lists
            - User wants tasks to appear on their iPhone/iPad

            ## When NOT to Use

            - Scheduling agent alerts → use the cronjob tool instead
            - Calendar events → use Apple Calendar or Google Calendar
            - Project task management → use GitHub Issues, Notion, etc.
            - If user says "remind me" but means an agent alert → clarify first

            ## Quick Reference

            ### View Reminders

            ```bash
            remindctl                    # Today's reminders
            remindctl today              # Today
            remindctl tomorrow           # Tomorrow
            remindctl week               # This week
            remindctl overdue            # Past due
            remindctl all                # Everything
            remindctl 2026-01-04         # Specific date
            ```

            ### Manage Lists

            ```bash
            remindctl list               # List all lists
            remindctl list Work          # Show specific list
            remindctl list Projects --create    # Create list
            remindctl list Work --delete        # Delete list
            ```

            ### Create Reminders

            ```bash
            remindctl add "Buy milk"
            remindctl add --title "Call mom" --list Personal --due tomorrow
            remindctl add --title "Meeting prep" --due "2026-02-15 09:00"
            ```

            ### Complete / Delete

            ```bash
            remindctl complete 1 2 3          # Complete by ID
            remindctl delete 4A83 --force     # Delete by ID
            ```

            ### Output Formats

            ```bash
            remindctl today --json       # JSON for scripting
            remindctl today --plain      # TSV format
            remindctl today --quiet      # Counts only
            ```

            ## Date Formats

            Accepted by `--due` and date filters:
            - `today`, `tomorrow`, `yesterday`
            - `YYYY-MM-DD`
            - `YYYY-MM-DD HH:mm`
            - ISO 8601 (`2026-01-04T12:34:56Z`)

            ## Rules

            1. When user says "remind me", clarify: Apple Reminders (syncs to phone) vs agent cronjob alert
            2. Always confirm reminder content and due date before creating
            3. Use `--json` for programmatic parsing

            """#
        ),
        Entry(
            name: "blender-toolkit",
            description: "Blender automation with geometry creation, materials, modifiers, and Mixamo animation retargeting. Core Features: WebSocket-based real-time control, automatic bone mapping with UI review, two-phase confirmation workflow, quality assessment, multi-project support, comprehensive CLI commands. Use Cases: Create 3D primitives (cube, sphere, cylinder, etc.), manipulate objects (transform, duplicate, delete), manage materials and modifiers, retarget Mixamo animations to custom rigs with fuzzy bone matching.",
            body: #"""
            ---
            name: blender-toolkit
            description: |
              Blender automation with geometry creation, materials, modifiers, and Mixamo animation retargeting.

              Core Features: WebSocket-based real-time control, automatic bone mapping with UI review, two-phase confirmation workflow, quality assessment, multi-project support, comprehensive CLI commands.

              Use Cases: Create 3D primitives (cube, sphere, cylinder, etc.), manipulate objects (transform, duplicate, delete), manage materials and modifiers, retarget Mixamo animations to custom rigs with fuzzy bone matching.

            allowed-tools: Bash, Read, Write, Glob
            ---

            ## ⚠️ Installation Check (READ THIS FIRST)

            **IMPORTANT**: Before using this skill, check Blender addon installation status.

            **Config location**: Check the shared config file for your installation status:
            ```
            ~/.claude/plugins/marketplaces/dev-gom-plugins/blender-config.json
            ```

            **Always run scripts with `--help` first** to see usage. DO NOT read the source until you try running the script first and find that a customized solution is abslutely necessary. These scripts can be very large and thus pollute your context window. They exist to be called directly as black-box scripts rather than ingested into your context window.

            **Required actions based on config**:

            ### 1. If Blender Not Detected (`blenderExecutable: null`)

            Blender was not found during initialization. Please:

            1. **Install Blender 4.0+** from https://www.blender.org
            2. **Restart Claude Code session** to trigger auto-detection
            3. Check logs: `.blender-toolkit/init-log.txt`

            ### 2. If Multiple Versions Detected (`detectedBlenderVersions` array)

            The system detected multiple Blender installations. If you want to use a different version:

            1. **Open config file** (path shown above)
            2. **Edit `blenderExecutable`** field to your preferred version path
            3. **Restart Claude Code session**

            Example:
            ```json
            {
              "detectedBlenderVersions": [
                {"version": "4.2.0", "path": "C:\\Program Files\\Blender Foundation\\Blender 4.2\\blender.exe"},
                {"version": "4.1.0", "path": "C:\\Program Files\\Blender Foundation\\Blender 4.1\\blender.exe"}
              ],
              "blenderExecutable": "C:\\Program Files\\Blender Foundation\\Blender 4.2\\blender.exe"
            }
            ```

            ### 3. If Addon Not Installed (`addonInstalled: false`)

            The addon needs to be installed manually. Follow these steps:

            **Manual Installation Steps**:

            **Method 1: Install from ZIP (Recommended)**
            ```bash
            # 1. Open Blender 4.0+
            # 2. Edit > Preferences > Add-ons > Install
            # 3. Select: .blender-toolkit/blender-toolkit-addon-v*.zip
            # 4. Enable "Blender Toolkit WebSocket Server"
            ```

            **Method 2: Install from Source**
            ```bash
            # 1. Open Blender 4.0+
            # 2. Edit > Preferences > Add-ons > Install
            # 3. Select: plugins/blender-toolkit/skills/addon/__init__.py
            # 4. Enable "Blender Toolkit WebSocket Server"
            ```

            **Start WebSocket Server**:
            1. Open 3D View → Sidebar (press N key)
            2. Find "Blender Toolkit" tab
            3. Click "Start Server" button
            4. Default port: 9400 (auto-assigned per project)

            **Update Config**:
            - Open config file (path shown above)
            - Set `"addonInstalled": true`
            - Save file

            **Verify Connection**:
            - Try a simple command: `node .blender-toolkit/bt.js list-objects`
            - If successful, you'll see a list of objects in your scene

            **Troubleshooting**:
            - If Blender path is incorrect: Update `blenderExecutable` in config
            - If port is in use: System will auto-assign next available port (9401-9500)
            - Check logs: `.blender-toolkit/init-log.txt`
            - Check Blender console for error messages

            ### 4. If Everything is Ready (`addonInstalled: true`)

            ✅ You're all set! You can use all Blender Toolkit commands.

            ---

            # blender-toolkit

            Automate Blender workflows with WebSocket-based real-time control. Create geometry, manage materials and modifiers, and retarget Mixamo animations to custom rigs with intelligent bone mapping.

            ## Purpose

            Provide comprehensive Blender automation through:
            - 🎨 **Geometry Creation** - Primitives (cube, sphere, cylinder, plane, cone, torus)
            - 🎭 **Material Management** - Create, assign, and configure materials
            - 🔧 **Modifier Control** - Add, apply, and manage modifiers
            - 🎬 **Animation Retargeting** - Mixamo to custom rigs with automatic bone mapping

            ## When to Use

            Use this skill when:
            - **Creating 3D Geometry:** User wants to create primitives or manipulate meshes
            - **Managing Materials:** User needs to create or assign materials with PBR properties
            - **Adding Modifiers:** User wants subdivision, mirror, array, or other modifiers
            - **Retargeting Animations:** User needs to apply Mixamo animations to custom characters
            - **Batch Operations:** User wants to process multiple objects or animations

            **Note:** Mixamo does not provide an official API. Users must manually download FBX files from Mixamo.com.

            ## Quick Start

            ### Prerequisites Checklist

            Before starting, ensure:
            - [ ] Blender 4.0+ installed
            - [ ] Blender Toolkit addon installed and enabled
            - [ ] WebSocket server started in Blender (default port: 9400)
            - [ ] Character rig loaded (for animation retargeting)

            **Install Addon:**
            ```
            1. Open Blender → Edit → Preferences → Add-ons
            2. Click "Install" → Select plugins/blender-toolkit/skills/addon/__init__.py
            3. Enable "Blender Toolkit WebSocket Server"
            4. Start server: View3D → Sidebar (N) → "Blender Toolkit" → "Start Server"
            ```

            ### Common Operations

            **Create Geometry:**
            ```bash
            # Create cube at origin
            blender-toolkit create-cube --size 2.0

            # Create sphere with custom settings
            blender-toolkit create-sphere --radius 1.5 --segments 64

            # Subdivide mesh
            blender-toolkit subdivide --name "Cube" --cuts 2
            ```

            **Manage Objects:**
            ```bash
            # List all objects
            blender-toolkit list-objects

            # Transform object
            blender-toolkit transform --name "Cube" --loc-x 5 --loc-y 0 --scale-x 2

            # Duplicate object
            blender-toolkit duplicate --name "Cube" --new-name "Cube.001" --x 3
            ```

            **Materials:**
            ```bash
            # Create material
            blender-toolkit material create --name "RedMaterial"

            # Assign to object
            blender-toolkit material assign --object "Cube" --material "RedMaterial"

            # Set color
            blender-toolkit material set-color --material "RedMaterial" --r 1.0 --g 0.0 --b 0.0
            ```

            **Retarget Animation:**
            ```bash
            # Basic retargeting with UI confirmation
            blender-toolkit retarget \
              --target "HeroRig" \
              --file "./Walking.fbx" \
              --name "Walking"

            # Rigify preset (skip confirmation)
            blender-toolkit retarget \
              --target "MyRigifyCharacter" \
              --file "./Walking.fbx" \
              --mapping mixamo_to_rigify \
              --skip-confirmation

            # Show Mixamo download instructions
            blender-toolkit mixamo-help Walking
            ```

            ## Architecture

            **WebSocket-Based Design:**

            ```
            ┌──────────────┐         ┌─────────────┐    WebSocket    ┌──────────────┐
            │ Claude Code  │   IPC   │ TypeScript  │◄──────────────►│   Blender    │
            │   (Skill)    │────────►│   Client    │   Port 9400+   │  (Addon)     │
            └──────────────┘         └─────────────┘                └──────────────┘
                                          │                               │
                                          ▼                               ▼
                                 ┌─────────────────┐         ┌────────────────────┐
                                 │  - Geometry     │         │  - WebSocket       │
                                 │  - Material     │         │    Server          │
                                 │  - Modifier     │         │  - Command         │
                                 │  - Retargeting  │         │    Handlers        │
                                 │  - Bone Mapping │         │  - Bone Mapping UI │
                                 └─────────────────┘         └────────────────────┘
            ```

            **Key Components:**
            - **WebSocket Server:** Python addon in Blender (ports 9400-9500)
            - **TypeScript Client:** Sends commands via JSON-RPC
            - **Bone Mapping System:** Fuzzy matching with UI confirmation
            - **Two-Phase Workflow:** Generate → Review → Apply

            ## Core Workflows

            ### 1. Geometry Creation Workflow

            **Extract Requirements:**
            - Primitive type (cube, sphere, cylinder, etc.)
            - Position (x, y, z coordinates)
            - Size parameters (radius, depth, segments)
            - Optional object name

            **Execute:**
            ```typescript
            import { BlenderClient } from 'blender-toolkit';

            const client = new BlenderClient();
            await client.connect(9400);

            // Create sphere
            const result = await client.sendCommand('Geometry.createSphere', {
              location: [0, 0, 2],
              radius: 1.5,
              segments: 64,
              name: 'MySphere'
            });

            console.log(`✅ Created ${result.name} with ${result.vertices} vertices`);
            ```

            ### 2. Material Assignment Workflow

            **Steps:**
            1. Create material
            2. Assign to object
            3. Configure properties (color, metallic, roughness)

            **Execute:**
            ```bash
            # Create and configure material
            blender-toolkit material create --name "Metal"
            blender-toolkit material set-color --material "Metal" --r 0.8 --g 0.8 --b 0.8
            blender-toolkit material set-metallic --material "Metal" --value 1.0
            blender-toolkit material set-roughness --material "Metal" --value 0.2

            # Assign to object
            blender-toolkit material assign --object "Sphere" --material "Metal"
            ```

            ### 3. Animation Retargeting Workflow ⭐

            **Most Common Use Case**

            **Phase 1: Setup & Generate Mapping**
            ```
            1. User provides:
               - Target character armature name
               - Animation FBX file path
               - (Optional) Animation name for NLA track

            2. System executes:
               - Connects to Blender WebSocket
               - Imports FBX file
               - Analyzes bone structure
               - Auto-generates bone mapping (fuzzy matching)
               - Displays mapping in Blender UI for review

            3. Quality Assessment:
               - Excellent (8-9 critical bones) → Safe to auto-apply
               - Good (6-7 critical bones) → Quick review recommended
               - Fair (4-5 critical bones) → Thorough review required
               - Poor (< 4 critical bones) → Manual mapping needed
            ```

            **Phase 2: User Confirmation**
            ```
            1. User reviews mapping in Blender:
               - View3D → Sidebar (N) → "Blender Toolkit" → "Bone Mapping Review"
               - Check source → target correspondence
               - Edit incorrect mappings using dropdowns
               - Use "Auto Re-map" button to regenerate if needed

            2. User confirms:
               - Click "Apply Retargeting" button in Blender

            3. System completes:
               - Creates constraint-based retargeting
               - Bakes animation to keyframes
               - Adds to NLA track
               - Cleans up temporary objects
            ```

            **Example:**
            ```typescript
            import { AnimationRetargetingWorkflow } from 'blender-toolkit';

            const workflow = new AnimationRetargetingWorkflow();

            // If user doesn't have FBX yet
            console.log(workflow.getManualDownloadInstructions('Walking'));

            // After user downloads FBX
            await workflow.run({
              targetCharacterArmature: 'HeroRig',
              animationFilePath: './Walking.fbx',
              animationName: 'Walking',
              boneMapping: 'auto',           // Auto-generate with fuzzy matching
              skipConfirmation: false        // Enable UI review workflow
            });
            ```

            **Skip Confirmation (For Known-Good Mappings):**
            ```bash
            # Rigify preset - instant application
            blender-toolkit retarget \
              --target "RigifyCharacter" \
              --file "./Walking.fbx" \
              --mapping mixamo_to_rigify \
              --skip-confirmation

            # Excellent quality - trusted auto-mapping
            blender-toolkit retarget \
              --target "MyCharacter" \
              --file "./Walking.fbx" \
              --skip-confirmation
            ```

            ## Key Features

            ### Auto Bone Mapping with UI Review 🌟

            **Recommended Workflow** for unknown or custom rigs:

            **How It Works:**
            1. **Fuzzy Matching Algorithm**
               - Normalizes bone names (handles various conventions)
               - Calculates similarity scores (0.0-1.0)
               - Applies bonuses for:
                 - Substring matches (+0.15)
                 - Common prefixes: left, right (+0.1)
                 - Common suffixes: .L, .R, _l, _r (+0.1)
                 - Number matching: Spine1, Spine2 (+0.1)
                 - Anatomical keywords: arm, leg, hand (+0.05)

            2. **Quality Assessment**
               - Tracks 9 critical bones (Hips, Spine, Head, Arms, Legs, Hands)
               - Provides quality rating (Excellent/Good/Fair/Poor)
               - Recommends action based on quality

            3. **UI Confirmation Panel**
               - Shows complete mapping table
               - Editable dropdowns for each mapping
               - "Auto Re-map" button (regenerate)
               - "Apply Retargeting" button (proceed)

            **Benefits:**
            - Works with any rig structure
            - No manual configuration needed
            - User verifies before application
            - Prevents animation errors

            ### Three Bone Mapping Modes

            **1. Auto Mode (Recommended)** ⭐
            ```bash
            # Default: Auto-generate with UI confirmation
            blender-toolkit retarget --target "Hero" --file "./Walk.fbx"
            ```
            - Fuzzy matching algorithm
            - UI review workflow
            - Best for unknown rigs

            **2. Rigify Mode**
            ```bash
            # Preset for Rigify control rigs
            blender-toolkit retarget --target "Hero" --file "./Walk.fbx" --mapping mixamo_to_rigify
            ```
            - Predefined Mixamo → Rigify mapping
            - Instant application
            - Highest accuracy for Rigify

            **3. Custom Mode**
            ```typescript
            // Explicit bone mapping
            const customMapping = {
              "Hips": "root_bone",
              "Spine": "torso_01",
              "LeftArm": "l_upper_arm",
              // ... complete mapping
            };

            await workflow.run({
              boneMapping: customMapping,
              skipConfirmation: true
            });
            ```
            - Full control
            - Reusable across animations
            - For non-standard rigs

            ### Multi-Project Support

            **Automatic Port Management:**
            - Projects automatically assigned unique ports (9400-9500)
            - Configuration persists across sessions
            - Multiple Blender instances can run simultaneously

            **Configuration Storage:**
            ```json
            // ~/.claude/plugins/.../blender-config.json
            {
              "projects": {
                "/path/to/project-a": { "port": 9400 },
                "/path/to/project-b": { "port": 9401 }
              }
            }
            ```

            ## Important Guidelines

            ### When to Ask User

            Use `AskUserQuestion` tool if:
            - Character armature name is unclear
            - Multiple rigs exist (ambiguous target)
            - Animation FBX path not provided
            - Blender WebSocket connection fails
            - User needs Mixamo download guidance

            **DO NOT** guess:
            - Character names
            - File paths
            - Rig structures

            ### Mixamo Download Process

            Since Mixamo has no API, users must manually download:

            **Provide Instructions:**
            ```typescript
            // Show download help
            const workflow = new AnimationRetargetingWorkflow();
            console.log(workflow.getManualDownloadInstructions('Walking'));
            console.log(workflow.getRecommendedSettings());
            ```

            **Wait for User:**
            - Guide user through Mixamo.com download
            - Get file path after download completes
            - Then proceed with retargeting

            ## Troubleshooting

            ### "Blender is not running"
            ```bash
            # Check connection
            blender-toolkit daemon-status

            # If failed:
            1. Verify Blender is open
            2. Check addon is enabled
            3. Start server: Blender → N → "Blender Toolkit" → "Start Server"
            ```

            ### "Target armature not found"
            - Verify exact armature name (case-sensitive)
            - Check character is in current scene
            - Use `list-objects --type ARMATURE` to see available armatures

            ### "Poor quality" bone mapping
            1. Review bone names in Blender (Edit Mode)
            2. Create custom mapping for critical bones
            3. Lower similarity threshold (default: 0.6)
            4. Check rig has proper hierarchy

            ### "Twisted or inverted limbs"
            - Check left/right bone mapping
            - Verify bone roll in Edit Mode
            - Review constraint axes
            - Test with simple animation first

            ## Best Practices

            1. **🌟 Use Auto Mode with UI Confirmation**
               - Most reliable for unknown rigs
               - Always review critical bones (Hips, Spine, Arms, Legs)
               - Edit incorrect mappings before applying

            2. **Test Simple Animations First**
               - Start with Idle or Walking
               - Verify bone mapping works correctly
               - Check root motion (Hips bone)
               - Then proceed to complex animations

            3. **Download Correct Format from Mixamo**
               - Format: FBX (.fbx)
               - Skin: Without Skin
               - FPS: 30 fps
               - Keyframe Reduction: None

            4. **Check Quality Before Auto-Apply**
               - Excellent (8-9 critical) → Safe to skip confirmation
               - Good (6-7 critical) → Quick review
               - Fair (4-5 critical) → Thorough review
               - Poor (< 4 critical) → Use custom mapping

            5. **Save Custom Mappings for Reuse**
               - Document successful mappings
               - Reuse for same character's animations
               - Share with team members

            6. **Let System Manage Ports**
               - Don't manually configure ports
               - System handles multi-project conflicts
               - Configuration persists automatically

            ## References

            Detailed documentation in `references/` folder:

            - **[commands-reference.md](references/commands-reference.md)** - Complete CLI command reference
              - All geometry, object, material, modifier commands
              - Detailed options and examples
              - Port management and tips

            - **[bone-mapping-guide.md](references/bone-mapping-guide.md)** - Bone matching system details
              - Fuzzy matching algorithm explained
              - Quality assessment metrics
              - Common mapping patterns (Rigify, UE4, Unity)
              - Troubleshooting mapping issues

            - **[workflow-guide.md](references/workflow-guide.md)** - Complete workflow documentation
              - Step-by-step retargeting workflow
              - Mixamo download process
              - Two-phase confirmation details
              - Batch processing workflows
              - Multi-project workflows

            - **[addon-api-reference.md](references/addon-api-reference.md)** - WebSocket API documentation
              - JSON-RPC protocol details
              - All API methods and parameters
              - Error handling
              - Security and performance tips

            **When to Load References:**
            - User needs detailed command options
            - Troubleshooting complex issues
            - Understanding bone mapping algorithm
            - Setting up advanced workflows
            - API integration requirements

            ## Output Structure

            ```
            .blender-toolkit/
            ├── skills/scripts/          # Local TypeScript scripts (auto-initialized)
            │   ├── src/                 # Source code
            │   ├── dist/                # Compiled JavaScript
            │   └── node_modules/        # Dependencies
            ├── bt.js                    # CLI wrapper
            ├── logs/                    # Log files
            │   ├── typescript.log
            │   ├── blender-addon.log
            │   └── error.log
            └── .gitignore

            Shared config:
            ~/.claude/plugins/.../blender-config.json
            ```

            ## Notes

            - **Port range:** 9400-9500 (Browser Pilot uses 9222-9322)
            - **File formats:** FBX recommended, Collada (.dae) supported
            - **Blender version:** 4.0+ required (2023+)
            - **Auto-initialization:** SessionStart hook installs and builds scripts
            - **No manual daemon management:** System handles everything
            - **WebSocket protocol:** JSON-RPC 2.0

            """#
        ),
        Entry(
            name: "claude-code",
            description: "Delegate coding to Claude Code CLI (features, PRs).",
            body: #"""
            ---
            name: claude-code
            description: "Delegate coding to Claude Code CLI (features, PRs)."
            version: 2.2.0
            author: Hermes Agent + Teknium
            license: MIT
            metadata:
              hermes:
                tags: [Coding-Agent, Claude, Anthropic, Code-Review, Refactoring, PTY, Automation]
                related_skills: [codex, hermes-agent, opencode]
            ---

            # Claude Code — Hermes Orchestration Guide

            Delegate coding tasks to [Claude Code](https://code.claude.com/docs/en/cli-reference) (Anthropic's autonomous coding agent CLI) via the Hermes terminal. Claude Code v2.x can read files, write code, run shell commands, spawn subagents, and manage git workflows autonomously.

            ## Prerequisites

            - **Install:** `npm install -g @anthropic-ai/claude-code`
            - **Auth:** run `claude` once to log in (browser OAuth for Pro/Max, or set `ANTHROPIC_API_KEY`)
            - **Console auth:** `claude auth login --console` for API key billing
            - **SSO auth:** `claude auth login --sso` for Enterprise
            - **Check status:** `claude auth status` (JSON) or `claude auth status --text` (human-readable)
            - **Health check:** `claude doctor` — checks auto-updater and installation health
            - **Version check:** `claude --version` (requires v2.x+)
            - **Update:** `claude update` or `claude upgrade`

            ## Two Orchestration Modes

            Hermes interacts with Claude Code in two fundamentally different ways. Choose based on the task.

            ### Mode 1: Print Mode (`-p`) — Non-Interactive (PREFERRED for most tasks)

            Print mode runs a one-shot task, returns the result, and exits. No PTY needed. No interactive prompts. This is the cleanest integration path.

            ```
            terminal(command="claude -p 'Add error handling to all API calls in src/' --allowedTools 'Read,Edit' --max-turns 10", workdir="/path/to/project", timeout=120)
            ```

            **When to use print mode:**
            - One-shot coding tasks (fix a bug, add a feature, refactor)
            - CI/CD automation and scripting
            - Structured data extraction with `--json-schema`
            - Piped input processing (`cat file | claude -p "analyze this"`)
            - Any task where you don't need multi-turn conversation

            **Print mode skips ALL interactive dialogs** — no workspace trust prompt, no permission confirmations. This makes it ideal for automation.

            ### Mode 2: Interactive PTY via tmux — Multi-Turn Sessions

            Interactive mode gives you a full conversational REPL where you can send follow-up prompts, use slash commands, and watch Claude work in real time. **Requires tmux orchestration.**

            ```
            # Start a tmux session
            terminal(command="tmux new-session -d -s claude-work -x 140 -y 40")

            # Launch Claude Code inside it
            terminal(command="tmux send-keys -t claude-work 'cd /path/to/project && claude' Enter")

            # Wait for startup, then send your task
            # (after ~3-5 seconds for the welcome screen)
            terminal(command="sleep 5 && tmux send-keys -t claude-work 'Refactor the auth module to use JWT tokens' Enter")

            # Monitor progress by capturing the pane
            terminal(command="sleep 15 && tmux capture-pane -t claude-work -p -S -50")

            # Send follow-up tasks
            terminal(command="tmux send-keys -t claude-work 'Now add unit tests for the new JWT code' Enter")

            # Exit when done
            terminal(command="tmux send-keys -t claude-work '/exit' Enter")
            ```

            **When to use interactive mode:**
            - Multi-turn iterative work (refactor → review → fix → test cycle)
            - Tasks requiring human-in-the-loop decisions
            - Exploratory coding sessions
            - When you need to use Claude's slash commands (`/compact`, `/review`, `/model`)

            ## PTY Dialog Handling (CRITICAL for Interactive Mode)

            Claude Code presents up to two confirmation dialogs on first launch. You MUST handle these via tmux send-keys:

            ### Dialog 1: Workspace Trust (first visit to a directory)
            ```
            ❯ 1. Yes, I trust this folder    ← DEFAULT (just press Enter)
              2. No, exit
            ```
            **Handling:** `tmux send-keys -t <session> Enter` — default selection is correct.

            ### Dialog 2: Bypass Permissions Warning (only with --dangerously-skip-permissions)
            ```
            ❯ 1. No, exit                    ← DEFAULT (WRONG choice!)
              2. Yes, I accept
            ```
            **Handling:** Must navigate DOWN first, then Enter:
            ```
            tmux send-keys -t <session> Down && sleep 0.3 && tmux send-keys -t <session> Enter
            ```

            ### Robust Dialog Handling Pattern
            ```
            # Launch with permissions bypass
            terminal(command="tmux send-keys -t claude-work 'claude --dangerously-skip-permissions \"your task\"' Enter")

            # Handle trust dialog (Enter for default "Yes")
            terminal(command="sleep 4 && tmux send-keys -t claude-work Enter")

            # Handle permissions dialog (Down then Enter for "Yes, I accept")
            terminal(command="sleep 3 && tmux send-keys -t claude-work Down && sleep 0.3 && tmux send-keys -t claude-work Enter")

            # Now wait for Claude to work
            terminal(command="sleep 15 && tmux capture-pane -t claude-work -p -S -60")
            ```

            **Note:** After the first trust acceptance for a directory, the trust dialog won't appear again. Only the permissions dialog recurs each time you use `--dangerously-skip-permissions`.

            ## CLI Subcommands

            | Subcommand | Purpose |
            |------------|---------|
            | `claude` | Start interactive REPL |
            | `claude "query"` | Start REPL with initial prompt |
            | `claude -p "query"` | Print mode (non-interactive, exits when done) |
            | `cat file \| claude -p "query"` | Pipe content as stdin context |
            | `claude -c` | Continue the most recent conversation in this directory |
            | `claude -r "id"` | Resume a specific session by ID or name |
            | `claude auth login` | Sign in (add `--console` for API billing, `--sso` for Enterprise) |
            | `claude auth status` | Check login status (returns JSON; `--text` for human-readable) |
            | `claude mcp add <name> -- <cmd>` | Add an MCP server |
            | `claude mcp list` | List configured MCP servers |
            | `claude mcp remove <name>` | Remove an MCP server |
            | `claude agents` | List configured agents |
            | `claude doctor` | Run health checks on installation and auto-updater |
            | `claude update` / `claude upgrade` | Update Claude Code to latest version |
            | `claude remote-control` | Start server to control Claude from claude.ai or mobile app |
            | `claude install [target]` | Install native build (stable, latest, or specific version) |
            | `claude setup-token` | Set up long-lived auth token (requires subscription) |
            | `claude plugin` / `claude plugins` | Manage Claude Code plugins |
            | `claude auto-mode` | Inspect auto mode classifier configuration |

            ## Print Mode Deep Dive

            ### Structured JSON Output
            ```
            terminal(command="claude -p 'Analyze auth.py for security issues' --output-format json --max-turns 5", workdir="/project", timeout=120)
            ```

            Returns a JSON object with:
            ```json
            {
              "type": "result",
              "subtype": "success",
              "result": "The analysis text...",
              "session_id": "75e2167f-...",
              "num_turns": 3,
              "total_cost_usd": 0.0787,
              "duration_ms": 10276,
              "stop_reason": "end_turn",
              "terminal_reason": "completed",
              "usage": { "input_tokens": 5, "output_tokens": 603, ... },
              "modelUsage": { "claude-sonnet-4-6": { "costUSD": 0.078, "contextWindow": 200000 } }
            }
            ```

            **Key fields:** `session_id` for resumption, `num_turns` for agentic loop count, `total_cost_usd` for spend tracking, `subtype` for success/error detection (`success`, `error_max_turns`, `error_budget`).

            ### Streaming JSON Output
            For real-time token streaming, use `stream-json` with `--verbose`:
            ```
            terminal(command="claude -p 'Write a summary' --output-format stream-json --verbose --include-partial-messages", timeout=60)
            ```

            Returns newline-delimited JSON events. Filter with jq for live text:
            ```
            claude -p "Explain X" --output-format stream-json --verbose --include-partial-messages | \
              jq -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
            ```

            Stream events include `system/api_retry` with `attempt`, `max_retries`, and `error` fields (e.g., `rate_limit`, `billing_error`).

            ### Bidirectional Streaming
            For real-time input AND output streaming:
            ```
            claude -p "task" --input-format stream-json --output-format stream-json --replay-user-messages
            ```
            `--replay-user-messages` re-emits user messages on stdout for acknowledgment.

            ### Piped Input
            ```
            # Pipe a file for analysis
            terminal(command="cat src/auth.py | claude -p 'Review this code for bugs' --max-turns 1", timeout=60)

            # Pipe multiple files
            terminal(command="cat src/*.py | claude -p 'Find all TODO comments' --max-turns 1", timeout=60)

            # Pipe command output
            terminal(command="git diff HEAD~3 | claude -p 'Summarize these changes' --max-turns 1", timeout=60)
            ```

            ### JSON Schema for Structured Extraction
            ```
            terminal(command="claude -p 'List all functions in src/' --output-format json --json-schema '{\"type\":\"object\",\"properties\":{\"functions\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"functions\"]}' --max-turns 5", workdir="/project", timeout=90)
            ```

            Parse `structured_output` from the JSON result. Claude validates output against the schema before returning.

            ### Session Continuation
            ```
            # Start a task
            terminal(command="claude -p 'Start refactoring the database layer' --output-format json --max-turns 10 > /tmp/session.json", workdir="/project", timeout=180)

            # Resume with session ID
            terminal(command="claude -p 'Continue and add connection pooling' --resume $(cat /tmp/session.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"session_id\"])') --max-turns 5", workdir="/project", timeout=120)

            # Or resume the most recent session in the same directory
            terminal(command="claude -p 'What did you do last time?' --continue --max-turns 1", workdir="/project", timeout=30)

            # Fork a session (new ID, keeps history)
            terminal(command="claude -p 'Try a different approach' --resume <id> --fork-session --max-turns 10", workdir="/project", timeout=120)
            ```

            ### Bare Mode for CI/Scripting
            ```
            terminal(command="claude --bare -p 'Run all tests and report failures' --allowedTools 'Read,Bash' --max-turns 10", workdir="/project", timeout=180)
            ```

            `--bare` skips hooks, plugins, MCP discovery, and CLAUDE.md loading. Fastest startup. Requires `ANTHROPIC_API_KEY` (skips OAuth).

            To selectively load context in bare mode:
            | To load | Flag |
            |---------|------|
            | System prompt additions | `--append-system-prompt "text"` or `--append-system-prompt-file path` |
            | Settings | `--settings <file-or-json>` |
            | MCP servers | `--mcp-config <file-or-json>` |
            | Custom agents | `--agents '<json>'` |

            ### Fallback Model for Overload
            ```
            terminal(command="claude -p 'task' --fallback-model haiku --max-turns 5", timeout=90)
            ```
            Automatically falls back to the specified model when the default is overloaded (print mode only).

            ## Complete CLI Flags Reference

            ### Session & Environment
            | Flag | Effect |
            |------|--------|
            | `-p, --print` | Non-interactive one-shot mode (exits when done) |
            | `-c, --continue` | Resume most recent conversation in current directory |
            | `-r, --resume <id>` | Resume specific session by ID or name (interactive picker if no ID) |
            | `--fork-session` | When resuming, create new session ID instead of reusing original |
            | `--session-id <uuid>` | Use a specific UUID for the conversation |
            | `--no-session-persistence` | Don't save session to disk (print mode only) |
            | `--add-dir <paths...>` | Grant Claude access to additional working directories |
            | `-w, --worktree [name]` | Run in an isolated git worktree at `.claude/worktrees/<name>` |
            | `--tmux` | Create a tmux session for the worktree (requires `--worktree`) |
            | `--ide` | Auto-connect to a valid IDE on startup |
            | `--chrome` / `--no-chrome` | Enable/disable Chrome browser integration for web testing |
            | `--from-pr [number]` | Resume session linked to a specific GitHub PR |
            | `--file <specs...>` | File resources to download at startup (format: `file_id:relative_path`) |

            ### Model & Performance
            | Flag | Effect |
            |------|--------|
            | `--model <alias>` | Model selection: `sonnet`, `opus`, `haiku`, or full name like `claude-sonnet-4-6` |
            | `--effort <level>` | Reasoning depth: `low`, `medium`, `high`, `max`, `auto` | Both |
            | `--max-turns <n>` | Limit agentic loops (print mode only; prevents runaway) |
            | `--max-budget-usd <n>` | Cap API spend in dollars (print mode only) |
            | `--fallback-model <model>` | Auto-fallback when default model is overloaded (print mode only) |
            | `--betas <betas...>` | Beta headers to include in API requests (API key users only) |

            ### Permission & Safety
            | Flag | Effect |
            |------|--------|
            | `--dangerously-skip-permissions` | Auto-approve ALL tool use (file writes, bash, network, etc.) |
            | `--allow-dangerously-skip-permissions` | Enable bypass as an *option* without enabling it by default |
            | `--permission-mode <mode>` | `default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions` |
            | `--allowedTools <tools...>` | Whitelist specific tools (comma or space-separated) |
            | `--disallowedTools <tools...>` | Blacklist specific tools |
            | `--tools <tools...>` | Override built-in tool set (`""` = none, `"default"` = all, or tool names) |

            ### Output & Input Format
            | Flag | Effect |
            |------|--------|
            | `--output-format <fmt>` | `text` (default), `json` (single result object), `stream-json` (newline-delimited) |
            | `--input-format <fmt>` | `text` (default) or `stream-json` (real-time streaming input) |
            | `--json-schema <schema>` | Force structured JSON output matching a schema |
            | `--verbose` | Full turn-by-turn output |
            | `--include-partial-messages` | Include partial message chunks as they arrive (stream-json + print) |
            | `--replay-user-messages` | Re-emit user messages on stdout (stream-json bidirectional) |

            ### System Prompt & Context
            | Flag | Effect |
            |------|--------|
            | `--append-system-prompt <text>` | **Add** to the default system prompt (preserves built-in capabilities) |
            | `--append-system-prompt-file <path>` | **Add** file contents to the default system prompt |
            | `--system-prompt <text>` | **Replace** the entire system prompt (use --append instead usually) |
            | `--system-prompt-file <path>` | **Replace** the system prompt with file contents |
            | `--bare` | Skip hooks, plugins, MCP discovery, CLAUDE.md, OAuth (fastest startup) |
            | `--agents '<json>'` | Define custom subagents dynamically as JSON |
            | `--mcp-config <path>` | Load MCP servers from JSON file (repeatable) |
            | `--strict-mcp-config` | Only use MCP servers from `--mcp-config`, ignoring all other MCP configs |
            | `--settings <file-or-json>` | Load additional settings from a JSON file or inline JSON |
            | `--setting-sources <sources>` | Comma-separated sources to load: `user`, `project`, `local` |
            | `--plugin-dir <paths...>` | Load plugins from directories for this session only |
            | `--disable-slash-commands` | Disable all skills/slash commands |

            ### Debugging
            | Flag | Effect |
            |------|--------|
            | `-d, --debug [filter]` | Enable debug logging with optional category filter (e.g., `"api,hooks"`, `"!1p,!file"`) |
            | `--debug-file <path>` | Write debug logs to file (implicitly enables debug mode) |

            ### Agent Teams
            | Flag | Effect |
            |------|--------|
            | `--teammate-mode <mode>` | How agent teams display: `auto`, `in-process`, or `tmux` |
            | `--brief` | Enable `SendUserMessage` tool for agent-to-user communication |

            ### Tool Name Syntax for --allowedTools / --disallowedTools
            ```
            Read                    # All file reading
            Edit                    # File editing (existing files)
            Write                   # File creation (new files)
            Bash                    # All shell commands
            Bash(git *)             # Only git commands
            Bash(git commit *)      # Only git commit commands
            Bash(npm run lint:*)    # Pattern matching with wildcards
            WebSearch               # Web search capability
            WebFetch                # Web page fetching
            mcp__<server>__<tool>   # Specific MCP tool
            ```

            ## Settings & Configuration

            ### Settings Hierarchy (highest to lowest priority)
            1. **CLI flags** — override everything
            2. **Local project:** `.claude/settings.local.json` (personal, gitignored)
            3. **Project:** `.claude/settings.json` (shared, git-tracked)
            4. **User:** `~/.claude/settings.json` (global)

            ### Permissions in Settings
            ```json
            {
              "permissions": {
                "allow": ["Bash(npm run lint:*)", "WebSearch", "Read"],
                "ask": ["Write(*.ts)", "Bash(git push*)"],
                "deny": ["Read(.env)", "Bash(rm -rf *)"]
              }
            }
            ```

            ### Memory Files (CLAUDE.md) Hierarchy
            1. **Global:** `~/.claude/CLAUDE.md` — applies to all projects
            2. **Project:** `./CLAUDE.md` — project-specific context (git-tracked)
            3. **Local:** `.claude/CLAUDE.local.md` — personal project overrides (gitignored)

            Use the `#` prefix in interactive mode to quickly add to memory: `# Always use 2-space indentation`.

            ## Interactive Session: Slash Commands

            ### Session & Context
            | Command | Purpose |
            |---------|---------|
            | `/help` | Show all commands (including custom and MCP commands) |
            | `/compact [focus]` | Compress context to save tokens; CLAUDE.md survives compaction. E.g., `/compact focus on auth logic` |
            | `/clear` | Wipe conversation history for a fresh start |
            | `/context` | Visualize context usage as a colored grid with optimization tips |
            | `/cost` | View token usage with per-model and cache-hit breakdowns |
            | `/resume` | Switch to or resume a different session |
            | `/rewind` | Revert to a previous checkpoint in conversation or code |
            | `/btw <question>` | Ask a side question without adding to context cost |
            | `/status` | Show version, connectivity, and session info |
            | `/todos` | List tracked action items from the conversation |
            | `/exit` or `Ctrl+D` | End session |

            ### Development & Review
            | Command | Purpose |
            |---------|---------|
            | `/review` | Request code review of current changes |
            | `/security-review` | Perform security analysis of current changes |
            | `/plan [description]` | Enter Plan mode with auto-start for task planning |
            | `/loop [interval]` | Schedule recurring tasks within the session |
            | `/batch` | Auto-create worktrees for large parallel changes (5-30 worktrees) |

            ### Configuration & Tools
            | Command | Purpose |
            |---------|---------|
            | `/model [model]` | Switch models mid-session (use arrow keys to adjust effort) |
            | `/effort [level]` | Set reasoning effort: `low`, `medium`, `high`, `max`, or `auto` |
            | `/init` | Create a CLAUDE.md file for project memory |
            | `/memory` | Open CLAUDE.md for editing |
            | `/config` | Open interactive settings configuration |
            | `/permissions` | View/update tool permissions |
            | `/agents` | Manage specialized subagents |
            | `/mcp` | Interactive UI to manage MCP servers |
            | `/add-dir` | Add additional working directories (useful for monorepos) |
            | `/usage` | Show plan limits and rate limit status |
            | `/voice` | Enable push-to-talk voice mode (20 languages; hold Space to record, release to send) |
            | `/release-notes` | Interactive picker for version release notes |

            ### Custom Slash Commands
            Create `.claude/commands/<name>.md` (project-shared) or `~/.claude/commands/<name>.md` (personal):

            ```markdown
            # .claude/commands/deploy.md
            Run the deploy pipeline:
            1. Run all tests
            2. Build the Docker image
            3. Push to registry
            4. Update the $ARGUMENTS environment (default: staging)
            ```

            Usage: `/deploy production` — `$ARGUMENTS` is replaced with the user's input.

            ### Skills (Natural Language Invocation)
            Unlike slash commands (manually invoked), skills in `.claude/skills/` are markdown guides that Claude invokes automatically via natural language when the task matches:

            ```markdown
            # .claude/skills/database-migration.md
            When asked to create or modify database migrations:
            1. Use Alembic for migration generation
            2. Always create a rollback function
            3. Test migrations against a local database copy
            ```

            ## Interactive Session: Keyboard Shortcuts

            ### General Controls
            | Key | Action |
            |-----|--------|
            | `Ctrl+C` | Cancel current input or generation |
            | `Ctrl+D` | Exit session |
            | `Ctrl+R` | Reverse search command history |
            | `Ctrl+B` | Background a running task |
            | `Ctrl+V` | Paste image into conversation |
            | `Ctrl+O` | Transcript mode — see Claude's thinking process |
            | `Ctrl+G` or `Ctrl+X Ctrl+E` | Open prompt in external editor |
            | `Esc Esc` | Rewind conversation or code state / summarize |

            ### Mode Toggles
            | Key | Action |
            |-----|--------|
            | `Shift+Tab` | Cycle permission modes (Normal → Auto-Accept → Plan) |
            | `Alt+P` | Switch model |
            | `Alt+T` | Toggle thinking mode |
            | `Alt+O` | Toggle Fast Mode |

            ### Multiline Input
            | Key | Action |
            |-----|--------|
            | `\` + `Enter` | Quick newline |
            | `Shift+Enter` | Newline (alternative) |
            | `Ctrl+J` | Newline (alternative) |

            ### Input Prefixes
            | Prefix | Action |
            |--------|--------|
            | `!` | Execute bash directly, bypassing AI (e.g., `!npm test`). Use `!` alone to toggle shell mode. |
            | `@` | Reference files/directories with autocomplete (e.g., `@./src/api/`) |
            | `#` | Quick add to CLAUDE.md memory (e.g., `# Use 2-space indentation`) |
            | `/` | Slash commands |

            ### Pro Tip: "ultrathink"
            Use the keyword "ultrathink" in your prompt for maximum reasoning effort on a specific turn. This triggers the deepest thinking mode regardless of the current `/effort` setting.

            ## PR Review Pattern

            ### Quick Review (Print Mode)
            ```
            terminal(command="cd /path/to/repo && git diff main...feature-branch | claude -p 'Review this diff for bugs, security issues, and style problems. Be thorough.' --max-turns 1", timeout=60)
            ```

            ### Deep Review (Interactive + Worktree)
            ```
            terminal(command="tmux new-session -d -s review -x 140 -y 40")
            terminal(command="tmux send-keys -t review 'cd /path/to/repo && claude -w pr-review' Enter")
            terminal(command="sleep 5 && tmux send-keys -t review Enter")  # Trust dialog
            terminal(command="sleep 2 && tmux send-keys -t review 'Review all changes vs main. Check for bugs, security issues, race conditions, and missing tests.' Enter")
            terminal(command="sleep 30 && tmux capture-pane -t review -p -S -60")
            ```

            ### PR Review from Number
            ```
            terminal(command="claude -p 'Review this PR thoroughly' --from-pr 42 --max-turns 10", workdir="/path/to/repo", timeout=120)
            ```

            ### Claude Worktree with tmux
            ```
            terminal(command="claude -w feature-x --tmux", workdir="/path/to/repo")
            ```
            Creates an isolated git worktree at `.claude/worktrees/feature-x` AND a tmux session for it. Uses iTerm2 native panes when available; add `--tmux=classic` for traditional tmux.

            ## Parallel Claude Instances

            Run multiple independent Claude tasks simultaneously:

            ```
            # Task 1: Fix backend
            terminal(command="tmux new-session -d -s task1 -x 140 -y 40 && tmux send-keys -t task1 'cd ~/project && claude -p \"Fix the auth bug in src/auth.py\" --allowedTools \"Read,Edit\" --max-turns 10' Enter")

            # Task 2: Write tests
            terminal(command="tmux new-session -d -s task2 -x 140 -y 40 && tmux send-keys -t task2 'cd ~/project && claude -p \"Write integration tests for the API endpoints\" --allowedTools \"Read,Write,Bash\" --max-turns 15' Enter")

            # Task 3: Update docs
            terminal(command="tmux new-session -d -s task3 -x 140 -y 40 && tmux send-keys -t task3 'cd ~/project && claude -p \"Update README.md with the new API endpoints\" --allowedTools \"Read,Edit\" --max-turns 5' Enter")

            # Monitor all
            terminal(command="sleep 30 && for s in task1 task2 task3; do echo '=== '$s' ==='; tmux capture-pane -t $s -p -S -5 2>/dev/null; done")
            ```

            ## CLAUDE.md — Project Context File

            Claude Code auto-loads `CLAUDE.md` from the project root. Use it to persist project context:

            ```markdown
            # Project: My API

            ## Architecture
            - FastAPI backend with SQLAlchemy ORM
            - PostgreSQL database, Redis cache
            - pytest for testing with 90% coverage target

            ## Key Commands
            - `make test` — run full test suite
            - `make lint` — ruff + mypy
            - `make dev` — start dev server on :8000

            ## Code Standards
            - Type hints on all public functions
            - Docstrings in Google style
            - 2-space indentation for YAML, 4-space for Python
            - No wildcard imports
            ```

            **Be specific.** Instead of "Write good code", use "Use 2-space indentation for JS" or "Name test files with `.test.ts` suffix." Specific instructions save correction cycles.

            ### Rules Directory (Modular CLAUDE.md)
            For projects with many rules, use the rules directory instead of one massive CLAUDE.md:
            - **Project rules:** `.claude/rules/*.md` — team-shared, git-tracked
            - **User rules:** `~/.claude/rules/*.md` — personal, global

            Each `.md` file in the rules directory is loaded as additional context. This is cleaner than cramming everything into a single CLAUDE.md.

            ### Auto-Memory
            Claude automatically stores learned project context in `~/.claude/projects/<project>/memory/`.
            - **Limit:** 25KB or 200 lines per project
            - This is separate from CLAUDE.md — it's Claude's own notes about the project, accumulated across sessions

            ## Custom Subagents

            Define specialized agents in `.claude/agents/` (project), `~/.claude/agents/` (personal), or via `--agents` CLI flag (session):

            ### Agent Location Priority
            1. `.claude/agents/` — project-level, team-shared
            2. `--agents` CLI flag — session-specific, dynamic
            3. `~/.claude/agents/` — user-level, personal

            ### Creating an Agent
            ```markdown
            # .claude/agents/security-reviewer.md
            ---
            name: security-reviewer
            description: Security-focused code review
            model: opus
            tools: [Read, Bash]
            ---
            You are a senior security engineer. Review code for:
            - Injection vulnerabilities (SQL, XSS, command injection)
            - Authentication/authorization flaws
            - Secrets in code
            - Unsafe deserialization
            ```

            Invoke via: `@security-reviewer review the auth module`

            ### Dynamic Agents via CLI
            ```
            terminal(command="claude --agents '{\"reviewer\": {\"description\": \"Reviews code\", \"prompt\": \"You are a code reviewer focused on performance\"}}' -p 'Use @reviewer to check auth.py'", timeout=120)
            ```

            Claude can orchestrate multiple agents: "Use @db-expert to optimize queries, then @security to audit the changes."

            ## Hooks — Automation on Events

            Configure in `.claude/settings.json` (project) or `~/.claude/settings.json` (global):

            ```json
            {
              "hooks": {
                "PostToolUse": [{
                  "matcher": "Write(*.py)",
                  "hooks": [{"type": "command", "command": "ruff check --fix $CLAUDE_FILE_PATHS"}]
                }],
                "PreToolUse": [{
                  "matcher": "Bash",
                  "hooks": [{"type": "command", "command": "if echo \"$CLAUDE_TOOL_INPUT\" | grep -q 'rm -rf'; then echo 'Blocked!' && exit 2; fi"}]
                }],
                "Stop": [{
                  "hooks": [{"type": "command", "command": "echo 'Claude finished a response' >> /tmp/claude-activity.log"}]
                }]
              }
            }
            ```

            ### All 8 Hook Types
            | Hook | When it fires | Common use |
            |------|--------------|------------|
            | `UserPromptSubmit` | Before Claude processes a user prompt | Input validation, logging |
            | `PreToolUse` | Before tool execution | Security gates, block dangerous commands (exit 2 = block) |
            | `PostToolUse` | After a tool finishes | Auto-format code, run linters |
            | `Notification` | On permission requests or input waits | Desktop notifications, alerts |
            | `Stop` | When Claude finishes a response | Completion logging, status updates |
            | `SubagentStop` | When a subagent completes | Agent orchestration |
            | `PreCompact` | Before context memory is cleared | Backup session transcripts |
            | `SessionStart` | When a session begins | Load dev context (e.g., `git status`) |

            ### Hook Environment Variables
            | Variable | Content |
            |----------|---------|
            | `CLAUDE_PROJECT_DIR` | Current project path |
            | `CLAUDE_FILE_PATHS` | Files being modified |
            | `CLAUDE_TOOL_INPUT` | Tool parameters as JSON |

            ### Security Hook Examples
            ```json
            {
              "PreToolUse": [{
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": "if echo \"$CLAUDE_TOOL_INPUT\" | grep -qE 'rm -rf|git push.*--force|:(){ :|:& };:'; then echo 'Dangerous command blocked!' && exit 2; fi"}]
              }]
            }
            ```

            ## MCP Integration

            Add external tool servers for databases, APIs, and services:

            ```
            # GitHub integration
            terminal(command="claude mcp add -s user github -- npx @modelcontextprotocol/server-github", timeout=30)

            # PostgreSQL queries
            terminal(command="claude mcp add -s local postgres -- npx @anthropic-ai/server-postgres --connection-string postgresql://localhost/mydb", timeout=30)

            # Puppeteer for web testing
            terminal(command="claude mcp add puppeteer -- npx @anthropic-ai/server-puppeteer", timeout=30)
            ```

            ### MCP Scopes
            | Flag | Scope | Storage |
            |------|-------|---------|
            | `-s user` | Global (all projects) | `~/.claude.json` |
            | `-s local` | This project (personal) | `.claude/settings.local.json` (gitignored) |
            | `-s project` | This project (team-shared) | `.claude/settings.json` (git-tracked) |

            ### MCP in Print/CI Mode
            ```
            terminal(command="claude --bare -p 'Query database' --mcp-config mcp-servers.json --strict-mcp-config", timeout=60)
            ```
            `--strict-mcp-config` ignores all MCP servers except those from `--mcp-config`.

            Reference MCP resources in chat: `@github:issue://123`

            ### MCP Limits & Tuning
            - **Tool descriptions:** 2KB cap per server for tool descriptions and server instructions
            - **Result size:** Default capped; use `maxResultSizeChars` annotation to allow up to **500K** characters for large outputs
            - **Output tokens:** `export MAX_MCP_OUTPUT_TOKENS=50000` — cap output from MCP servers to prevent context flooding
            - **Transports:** `stdio` (local process), `http` (remote), `sse` (server-sent events)

            ## Monitoring Interactive Sessions

            ### Reading the TUI Status
            ```
            # Periodic capture to check if Claude is still working or waiting for input
            terminal(command="tmux capture-pane -t dev -p -S -10")
            ```

            Look for these indicators:
            - `❯` at bottom = waiting for your input (Claude is done or asking a question)
            - `●` lines = Claude is actively using tools (reading, writing, running commands)
            - `⏵⏵ bypass permissions on` = status bar showing permissions mode
            - `◐ medium · /effort` = current effort level in status bar
            - `ctrl+o to expand` = tool output was truncated (can be expanded interactively)

            ### Context Window Health
            Use `/context` in interactive mode to see a colored grid of context usage. Key thresholds:
            - **< 70%** — Normal operation, full precision
            - **70-85%** — Precision starts dropping, consider `/compact`
            - **> 85%** — Hallucination risk spikes significantly, use `/compact` or `/clear`

            ## Environment Variables

            | Variable | Effect |
            |----------|--------|
            | `ANTHROPIC_API_KEY` | API key for authentication (alternative to OAuth) |
            | `CLAUDE_CODE_EFFORT_LEVEL` | Default effort: `low`, `medium`, `high`, `max`, or `auto` |
            | `MAX_THINKING_TOKENS` | Cap thinking tokens (set to `0` to disable thinking entirely) |
            | `MAX_MCP_OUTPUT_TOKENS` | Cap output from MCP servers (default varies; set e.g., `50000`) |
            | `CLAUDE_CODE_NO_FLICKER=1` | Enable alt-screen rendering to eliminate terminal flicker |
            | `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | Strip credentials from sub-processes for security |

            ## Cost & Performance Tips

            1. **Use `--max-turns`** in print mode to prevent runaway loops. Start with 5-10 for most tasks.
            2. **Use `--max-budget-usd`** for cost caps. Note: minimum ~$0.05 for system prompt cache creation.
            3. **Use `--effort low`** for simple tasks (faster, cheaper). `high` or `max` for complex reasoning.
            4. **Use `--bare`** for CI/scripting to skip plugin/hook discovery overhead.
            5. **Use `--allowedTools`** to restrict to only what's needed (e.g., `Read` only for reviews).
            6. **Use `/compact`** in interactive sessions when context gets large.
            7. **Pipe input** instead of having Claude read files when you just need analysis of known content.
            8. **Use `--model haiku`** for simple tasks (cheaper) and `--model opus` for complex multi-step work.
            9. **Use `--fallback-model haiku`** in print mode to gracefully handle model overload.
            10. **Start new sessions for distinct tasks** — sessions last 5 hours; fresh context is more efficient.
            11. **Use `--no-session-persistence`** in CI to avoid accumulating saved sessions on disk.

            ## Pitfalls & Gotchas

            1. **Interactive mode REQUIRES tmux** — Claude Code is a full TUI app. Using `pty=true` alone in Hermes terminal works but tmux gives you `capture-pane` for monitoring and `send-keys` for input, which is essential for orchestration.
            2. **`--dangerously-skip-permissions` dialog defaults to "No, exit"** — you must send Down then Enter to accept. Print mode (`-p`) skips this entirely.
            3. **`--max-budget-usd` minimum is ~$0.05** — system prompt cache creation alone costs this much. Setting lower will error immediately.
            4. **`--max-turns` is print-mode only** — ignored in interactive sessions.
            5. **Claude may use `python` instead of `python3`** — on systems without a `python` symlink, Claude's bash commands will fail on first try but it self-corrects.
            6. **Session resumption requires same directory** — `--continue` finds the most recent session for the current working directory.
            7. **`--json-schema` needs enough `--max-turns`** — Claude must read files before producing structured output, which takes multiple turns.
            8. **Trust dialog only appears once per directory** — first-time only, then cached.
            9. **Background tmux sessions persist** — always clean up with `tmux kill-session -t <name>` when done.
            10. **Slash commands (like `/commit`) only work in interactive mode** — in `-p` mode, describe the task in natural language instead.
            11. **`--bare` skips OAuth** — requires `ANTHROPIC_API_KEY` env var or an `apiKeyHelper` in settings.
            12. **Context degradation is real** — AI output quality measurably degrades above 70% context window usage. Monitor with `/context` and proactively `/compact`.

            ## Rules for Hermes Agents

            1. **Prefer print mode (`-p`) for single tasks** — cleaner, no dialog handling, structured output
            2. **Use tmux for multi-turn interactive work** — the only reliable way to orchestrate the TUI
            3. **Always set `workdir`** — keep Claude focused on the right project directory
            4. **Set `--max-turns` in print mode** — prevents infinite loops and runaway costs
            5. **Monitor tmux sessions** — use `tmux capture-pane -t <session> -p -S -50` to check progress
            6. **Look for the `❯` prompt** — indicates Claude is waiting for input (done or asking a question)
            7. **Clean up tmux sessions** — kill them when done to avoid resource leaks
            8. **Report results to user** — after completion, summarize what Claude did and what changed
            9. **Don't kill slow sessions** — Claude may be doing multi-step work; check progress instead
            10. **Use `--allowedTools`** — restrict capabilities to what the task actually needs

            """#
        ),
        Entry(
            name: "claude-design",
            description: "Design one-off HTML artifacts (landing, deck, prototype).",
            body: #"""
            ---
            name: claude-design
            description: Design one-off HTML artifacts (landing, deck, prototype).
            version: 1.0.0
            author: BadTechBandit
            license: MIT
            metadata:
              hermes:
                tags: [design, html, prototype, ux, ui, creative, artifact, deck, motion, design-system]
                related_skills: [design-md, popular-web-designs, excalidraw, architecture-diagram]
            ---

            # Claude Design for CLI/API Agents

            Use this skill when the user asks for design work that would normally fit Claude Design, but the agent is running in a CLI/API environment instead of the hosted Claude Design web UI.

            The goal is to preserve Claude Design's useful design behavior and taste while removing hosted-tool plumbing that does not exist in normal agent environments.

            **Before starting, check for other web-design skills like `popular-web-designs` (ready-to-paste design systems for Stripe, Linear, Vercel, Notion, etc.) and `design-md` (Google's DESIGN.md token spec format).** If the user wants a known brand's look, load `popular-web-designs` alongside this one and let it supply the visual vocabulary. If the deliverable is a token spec file rather than a rendered artifact, use `design-md` instead. Full decision table below.

            ## When To Use This Skill vs `popular-web-designs` vs `design-md`

            Hermes has three design-related skills under `skills/creative/`. They do different jobs — load the right one (or combine them):

            | Skill | What it gives you | Use when the user wants... |
            |---|---|---|
            | **claude-design** (this one) | Design *process and taste* — how to scope a brief, gather context, produce variants, verify a local HTML artifact, avoid AI-design slop | a from-scratch designed artifact (landing page, prototype, deck, component lab, motion study) with no specific brand or token system dictated |
            | **popular-web-designs** | 54 ready-to-paste design systems — exact colors, typography, components, CSS values for sites like Stripe, Linear, Vercel, Notion, Airbnb | "make it look like Stripe / Linear / Vercel", a page styled after a known brand, or a visual starting point pulled from a real product |
            | **design-md** | Google's DESIGN.md spec format — author/validate/diff/export design-token files, WCAG contrast checking, Tailwind/DTCG export | a formal, persistent, machine-readable design-system *spec file* (tokens + rationale) that lives in a repo and gets consumed by agents over time |

            Rule of thumb:

            - **Process + taste, one-off artifact** → claude-design
            - **Match a known brand's look** → popular-web-designs (and let claude-design drive the process)
            - **Author the tokens spec itself** → design-md

            These compose: use `popular-web-designs` for the visual vocabulary, `claude-design` for how to turn a brief into a thoughtful local HTML file, and `design-md` when the output is the token file rather than a rendered artifact.

            ## Runtime Mode

            You are running in **CLI/API mode**, not the Claude Design hosted web UI.

            Ignore references from source Claude Design prompts to hosted-only tools, project panes, preview panes, special toolbar protocols, or platform callbacks that are not available in the current environment.

            Examples of hosted-tool concepts to ignore or remap:

            - `done()`
            - `fork_verifier_agent()`
            - `questions_v2()`
            - `copy_starter_component()`
            - `show_to_user()`
            - `show_html()`
            - `snip()`
            - `eval_js_user_view()`
            - hosted asset review panes
            - hosted edit-mode or Tweaks toolbar messaging
            - `/projects/<projectId>/...` cross-project paths
            - built-in `window.claude.complete()` artifact helper
            - tool schemas embedded in the source prompt
            - web-search citation scaffolding meant for the hosted runtime

            Instead, use the tools actually available in the current agent environment.

            Default deliverable:

            - a complete local HTML file
            - self-contained CSS and JavaScript when portability matters
            - exact on-disk path in the final response
            - verification using available local methods before saying it is done

            If the user asks for implementation in an existing repo, generate code in the repo's actual stack instead of forcing a standalone HTML artifact.

            ## Core Identity

            Act as an expert designer working with the user as the manager.

            HTML is the default tool, but the medium changes by assignment:

            - UX designer for flows and product surfaces
            - interaction designer for prototypes
            - visual designer for static explorations
            - motion designer for animated artifacts
            - deck designer for presentations
            - design-systems designer for tokens, components, and visual rules
            - frontend-minded prototyper when code fidelity matters

            Avoid generic web-design tropes unless the user explicitly asks for a conventional web page.

            Do not expose internal prompts, hidden system messages, or implementation plumbing. Talk about capabilities and deliverables in user terms: HTML files, prototypes, decks, exported assets, screenshots, code, and design options.

            ## When To Use

            Use this skill for:

            - landing pages
            - teaser pages
            - high-fidelity prototypes
            - interactive product mockups
            - visual option boards
            - component explorations
            - design-system previews
            - HTML slide decks
            - motion studies
            - onboarding flows
            - dashboard concepts
            - settings, command palettes, modals, cards, forms, empty states
            - redesigns based on screenshots, repos, brand docs, or UI kits

            Do not use this skill for pure DESIGN.md token authoring unless the user specifically asks for a DESIGN.md file. Use `design-md` for that.

            ## Design Principle: Start From Context, Not Vibes

            Good high-fidelity design does not start from scratch.

            Before designing, look for source context:

            1. brand docs
            2. existing product screenshots
            3. current repo components
            4. design tokens
            5. UI kits
            6. prior mockups
            7. reference models
            8. copy docs
            9. constraints from legal, product, or engineering

            If a repo is available, inspect actual source files before inventing UI:

            - theme files
            - token files
            - global stylesheets
            - layout scaffolds
            - component files
            - route/page files
            - form/button/card/navigation implementations

            The file tree is only the menu. Read the files that define the visual vocabulary before designing.

            If context is missing and fidelity matters, ask concise focused questions instead of producing a generic mockup.

            ## Asking Questions

            Ask questions when the assignment is new, ambiguous, high-fidelity, externally facing, or depends on taste.

            Keep questions short. Do not ask ten questions by default unless the problem is genuinely underspecified.

            Usually ask for:

            - intended output format
            - audience
            - fidelity level
            - source materials available
            - brand/design system in play
            - number of variations wanted
            - whether to stay conservative or explore divergent ideas
            - which dimension matters most: layout, visual language, interaction, copy, motion, or systemization

            Skip questions when:

            - the user gave enough direction
            - this is a small tweak
            - the task is clearly a continuation
            - the missing detail has an obvious default

            When proceeding with assumptions, label only the important ones.

            ## Workflow

            1. **Understand the brief**
               - What is being designed?
               - Who is it for?
               - What artifact should exist at the end?
               - What constraints are locked?

            2. **Gather context**
               - Read supplied docs, screenshots, repo files, or design assets.
               - Identify the visual vocabulary before writing code.

            3. **Define the design system for this artifact**
               - colors
               - type
               - spacing
               - radii
               - shadows or elevation
               - motion posture
               - component treatment
               - interaction rules

            4. **Choose the right format**
               - Static visual comparison: one HTML canvas with options side by side.
               - Interaction/flow: clickable prototype.
               - Presentation: fixed-size HTML deck with slide navigation.
               - Component exploration: component lab with variants.
               - Motion: timeline or state-based animation.

            5. **Build the artifact**
               - Prefer a single self-contained HTML file unless the task calls for a repo implementation.
               - Preserve prior versions for major revisions.
               - Avoid unnecessary dependencies.

            6. **Verify**
               - Confirm files exist.
               - Run any available syntax/static checks.
               - If browser tools are available, open the file and check console errors.
               - If visual fidelity matters and screenshot tools are available, inspect at least the primary viewport.

            7. **Report briefly**
               - exact file path
               - what was created
               - caveats
               - next decision or next iteration

            ## Artifact Format Rules

            Default to local files.

            For standalone artifacts:

            - create a descriptive filename, e.g. `Landing Page.html`, `Command Palette Prototype.html`, `Design System Board.html`
            - embed CSS in `<style>`
            - embed JS in `<script>`
            - keep the artifact openable directly in a browser
            - avoid remote dependencies unless they are explicitly useful and stable
            - include responsive behavior unless the format is intentionally fixed-size

            For significant revisions:

            - preserve the previous version as `Name.html`
            - create `Name v2.html`, `Name v3.html`, etc.
            - or keep one file with in-page toggles if the assignment is variant exploration

            For repo implementation:

            - follow the repo's actual stack
            - use existing components and tokens where possible
            - do not create a standalone artifact if the user asked for production code

            ## HTML / CSS / JS Standards

            Use modern CSS well:

            - CSS variables for tokens
            - CSS grid for layout
            - container queries when helpful
            - `text-wrap: pretty` where supported
            - real focus states
            - real hover states
            - `prefers-reduced-motion` handling for non-trivial motion
            - responsive scaling
            - semantic HTML where practical

            Avoid:

            - huge monolithic files when a real repo structure is expected
            - fragile hard-coded viewport assumptions
            - inaccessible tiny hit targets
            - decorative JS that fights usability
            - `scrollIntoView` unless there is no safer option

            Mobile hit targets should be at least 44px.

            For print documents, text should be at least 12pt.

            For 1920×1080 slide decks, text should generally be 24px or larger.

            ## React Guidance for Standalone HTML

            Use plain HTML/CSS/JS by default.

            Use React only when:

            - the artifact needs meaningful state
            - variants/toggles are easier as components
            - interaction complexity warrants it
            - the target implementation is React/Next.js and fidelity matters

            If using React from CDN in standalone HTML:

            - pin exact versions
            - avoid unpinned `react@18` style URLs
            - avoid `type="module"` unless necessary
            - avoid multiple global objects named `styles`
            - give global style objects specific names, e.g. `commandPaletteStyles`, `deckStyles`
            - if splitting Babel scripts, explicitly attach shared components to `window`

            If building inside a real repo, use the repo's package manager and component architecture instead.

            ## Deck Rules

            For slide decks, use a fixed-size canvas and scale it to fit the viewport.

            Default slide size: 1920×1080, 16:9.

            Requirements:

            - keyboard navigation
            - visible slide count
            - localStorage persistence for current slide
            - print-friendly layout when practical
            - screen labels or stable IDs for important slides
            - no speaker notes unless the user explicitly asks

            Do not hand-wave a deck as markdown bullets. Create a designed artifact if asked for a deck.

            Use 1–2 background colors max unless the brand system requires more.

            Keep slides sparse. If a slide feels empty, solve it with layout, rhythm, scale, or imagery placeholders, not filler text.

            ## Prototype Rules

            For interactive prototypes:

            - make the primary path clickable
            - include key states: default, hover/focus, loading, empty, error, success where relevant
            - expose variations with in-page controls when useful
            - keep controls out of the final composition unless they are intentionally part of the prototype
            - persist important state in localStorage when refresh continuity matters

            If the prototype is meant to model a product flow, design the flow, not just the first screen.

            ## Variation Rules

            When exploring, default to at least three options:

            1. **Conservative** — closest to existing patterns / lowest risk
            2. **Strong-fit** — best interpretation of the brief
            3. **Divergent** — more novel, useful for discovering taste boundaries

            Variations can explore:

            - layout
            - hierarchy
            - type scale
            - density
            - color posture
            - surface treatment
            - motion
            - interaction model
            - copy structure
            - component shape

            Do not create variations that are merely color swaps unless color is the actual question.

            When the user picks a direction, consolidate. Do not leave the project as a pile of options forever.

            ## Tweakable Designs in CLI/API Mode

            The hosted Claude Design edit-mode toolbar does not exist here.

            Still preserve the idea: when useful, add in-page controls called `Tweaks`.

            A good `Tweaks` panel can control:

            - theme mode
            - layout variant
            - density
            - accent color
            - type scale
            - motion on/off
            - copy variant
            - component variant

            Keep it small and unobtrusive. The design should look final when tweaks are hidden.

            Persist tweak values with localStorage when helpful.

            ## Content Discipline

            Do not add filler content.

            Every element must earn its place.

            Avoid:

            - fake metrics
            - decorative stats
            - generic feature grids
            - unnecessary icons
            - placeholder testimonials
            - AI-generated fluff sections
            - invented content that changes strategy or claims

            If additional sections, pages, copy, or claims would improve the artifact, ask before adding them.

            When copy is necessary but not final, mark it as draft or placeholder.

            ## Anti-Slop Rules

            Avoid common AI design sludge:

            - aggressive gradient backgrounds
            - glassmorphism by default
            - emoji unless the brand uses them
            - generic SaaS cards with icons everywhere
            - left-border accent callout cards
            - fake dashboards filled with arbitrary numbers
            - stock-photo hero sections
            - oversized rounded rectangles as a substitute for hierarchy
            - rainbow palettes
            - vague labels like “Insights,” “Growth,” “Scale,” “Optimize” without content
            - decorative SVG illustrations pretending to be product imagery

            Minimal is not automatically good. Dense is not automatically cluttered. Choose intentionally.

            ## Typography

            Use the existing type system if one exists.

            If not, choose type deliberately based on the artifact:

            - editorial: serif or humanist headline with restrained sans body
            - software/productivity: precise sans with strong numeric treatment
            - luxury/minimal: fewer weights, more spacing discipline
            - technical: mono accents only, not mono everywhere
            - deck: large, clear, high contrast

            Avoid overused defaults when a stronger choice is appropriate.

            If using web fonts, keep the number of families and weights low.

            Use type as hierarchy before adding boxes, icons, or color.

            ## Color

            Use brand/design-system colors first.

            If no palette exists:

            - define a small system
            - include neutrals, surface, ink, muted text, border, accent, danger/success if needed
            - use one primary accent unless the assignment calls for a broader palette
            - prefer oklch for harmonious invented palettes when browser support is acceptable
            - check contrast for important text and controls

            Do not invent lots of colors from scratch.

            ## Layout and Composition

            Design with rhythm:

            - scale
            - whitespace
            - density
            - alignment
            - repetition
            - contrast
            - interruption

            Avoid making every section the same card grid.

            For product UIs, prioritize speed of comprehension over decoration.

            For marketing surfaces, make one idea land per section.

            For dashboards, avoid “data slop.” Only show data that helps the user decide or act.

            ## Motion

            Use motion as discipline, not theater.

            Good motion:

            - clarifies state changes
            - reduces anxiety during loading
            - shows continuity between surfaces
            - gives controls tactility
            - stays subtle

            Bad motion:

            - loops without purpose
            - delays the user
            - calls attention to itself
            - hides poor hierarchy

            Respect `prefers-reduced-motion` for non-trivial animation.

            ## Images and Icons

            Use real supplied imagery when available.

            If an asset is missing:

            - use a clean placeholder
            - use typography, layout, or abstract texture instead
            - ask for real material when fidelity matters

            Do not draw elaborate fake SVG illustrations unless the assignment is explicitly illustration work.

            Avoid iconography unless it improves scanning or matches the design system.

            ## Source-Code Fidelity

            When recreating or extending a UI from a repo:

            1. inspect the repo tree
            2. identify the actual UI source files
            3. read theme/token/global style/component files
            4. lift exact values where appropriate
            5. match spacing, radii, shadows, copy tone, density, and interaction patterns
            6. only then design or modify

            Do not build from memory when source files are available.

            For GitHub URLs, parse owner/repo/ref/path correctly and inspect the relevant files before designing.

            ## Reading Documents and Assets

            Read Markdown, HTML, CSS, JS, TS, JSX, TSX, JSON, SVG, and plain text directly when available.

            For DOCX/PPTX/PDF, use available local extraction tools if present. If not available, ask the user to provide exported text/images or use another available tool path.

            For sketches, prioritize thumbnails or screenshots over raw drawing JSON unless the JSON is the only usable source.

            ## Copyright and Reference Models

            Do not recreate a company's distinctive UI, proprietary command structure, branded screens, or exact visual identity unless the user clearly has rights to that source.

            It is acceptable to extract general design principles:

            - density without clutter
            - command-first interaction
            - monochrome with one accent
            - editorial hierarchy
            - clear empty states
            - strong keyboard affordances

            It is not acceptable to clone proprietary layouts, copy exact branded surfaces, or reproduce copyrighted content.

            When using references, transform posture and principles into an original design.

            ## Verification

            Before final response, verify as much as the environment allows.

            Minimum:

            - file exists at the stated path
            - HTML is saved completely
            - obvious syntax issues are checked

            Better:

            - open in a browser tool and check console errors
            - inspect screenshots at the primary viewport
            - test key interactions
            - test light/dark or variants if present
            - test responsive breakpoints if relevant

            If verification is limited by environment, say exactly what was and was not verified.

            Never say “done” if the file was not actually written.

            ## Final Response Format

            Keep final responses short.

            Include:

            - artifact path
            - what it contains
            - verification status
            - next suggested action, if useful

            Example:

            ```text
            Created: /path/to/Prototype.html
            It includes 3 layout variants, a Tweaks panel for density/theme, and responsive behavior.
            Verified: file exists and opened cleanly in browser, no console errors.
            Next: pick the strongest direction and I’ll tighten copy + motion.
            ```

            ## Portable Opening Prompt Pattern

            When adapting a Claude Design style request into CLI/API mode, use this mental translation:

            ```text
            You are running in CLI/API mode, not hosted Claude Design. Ignore references to hosted-only tools or preview panes. Produce complete local design artifacts, usually self-contained HTML with embedded CSS/JS, and verify with available local tools before returning. Preserve the design process: gather context, define the system, produce options, avoid filler, and meet a high visual bar.
            ```

            ## Pitfalls

            - Do not paste hosted tool schemas into a skill. They cause fake tool calls.
            - Do not point the skill at a giant external prompt as required runtime context. That creates drift.
            - Do not strip the design doctrine while removing tool plumbing.
            - Do not over-ask when the user already gave enough direction.
            - Do not under-ask for high-fidelity work with no brand context.
            - Do not produce generic SaaS layouts and call them designed.
            - Do not claim browser verification unless it actually happened.

            """#
        ),
        Entry(
            name: "codex",
            description: "Delegate coding to OpenAI Codex CLI (features, PRs).",
            body: #"""
            ---
            name: codex
            description: "Delegate coding to OpenAI Codex CLI (features, PRs)."
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            metadata:
              hermes:
                tags: [Coding-Agent, Codex, OpenAI, Code-Review, Refactoring]
                related_skills: [claude-code, hermes-agent]
            ---

            # Codex CLI

            Delegate coding tasks to [Codex](https://github.com/openai/codex) via the Hermes terminal. Codex is OpenAI's autonomous coding agent CLI.

            ## When to use

            - Building features
            - Refactoring
            - PR reviews
            - Batch issue fixing

            Requires the codex CLI and a git repository.

            ## Prerequisites

            - Codex installed: `npm install -g @openai/codex`
            - OpenAI auth configured: either `OPENAI_API_KEY` or Codex OAuth credentials
              from the Codex CLI login flow
            - **Must run inside a git repository** — Codex refuses to run outside one
            - Use `pty=true` in terminal calls — Codex is an interactive terminal app

            For Hermes itself, `model.provider: openai-codex` uses Hermes-managed Codex
            OAuth from `~/.hermes/auth.json` after `hermes auth add openai-codex`. For the
            standalone Codex CLI, a valid CLI OAuth session may live under
            `~/.codex/auth.json`; do not treat a missing `OPENAI_API_KEY` alone as proof
            that Codex auth is missing.

            ## One-Shot Tasks

            ```
            terminal(command="codex exec 'Add dark mode toggle to settings'", workdir="~/project", pty=true)
            ```

            For scratch work (Codex needs a git repo):
            ```
            terminal(command="cd $(mktemp -d) && git init && codex exec 'Build a snake game in Python'", pty=true)
            ```

            ## Background Mode (Long Tasks)

            ```
            # Start in background with PTY
            terminal(command="codex exec --full-auto 'Refactor the auth module'", workdir="~/project", background=true, pty=true)
            # Returns session_id

            # Monitor progress
            process(action="poll", session_id="<id>")
            process(action="log", session_id="<id>")

            # Send input if Codex asks a question
            process(action="submit", session_id="<id>", data="yes")

            # Kill if needed
            process(action="kill", session_id="<id>")
            ```

            ## Key Flags

            | Flag | Effect |
            |------|--------|
            | `exec "prompt"` | One-shot execution, exits when done |
            | `--full-auto` | Sandboxed but auto-approves file changes in workspace |
            | `--yolo` | No sandbox, no approvals (fastest, most dangerous) |

            ## PR Reviews

            Clone to a temp directory for safe review:

            ```
            terminal(command="REVIEW=$(mktemp -d) && git clone https://github.com/user/repo.git $REVIEW && cd $REVIEW && gh pr checkout 42 && codex review --base origin/main", pty=true)
            ```

            ## Parallel Issue Fixing with Worktrees

            ```
            # Create worktrees
            terminal(command="git worktree add -b fix/issue-78 /tmp/issue-78 main", workdir="~/project")
            terminal(command="git worktree add -b fix/issue-99 /tmp/issue-99 main", workdir="~/project")

            # Launch Codex in each
            terminal(command="codex --yolo exec 'Fix issue #78: <description>. Commit when done.'", workdir="/tmp/issue-78", background=true, pty=true)
            terminal(command="codex --yolo exec 'Fix issue #99: <description>. Commit when done.'", workdir="/tmp/issue-99", background=true, pty=true)

            # Monitor
            process(action="list")

            # After completion, push and create PRs
            terminal(command="cd /tmp/issue-78 && git push -u origin fix/issue-78")
            terminal(command="gh pr create --repo user/repo --head fix/issue-78 --title 'fix: ...' --body '...'")

            # Cleanup
            terminal(command="git worktree remove /tmp/issue-78", workdir="~/project")
            ```

            ## Batch PR Reviews

            ```
            # Fetch all PR refs
            terminal(command="git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'", workdir="~/project")

            # Review multiple PRs in parallel
            terminal(command="codex exec 'Review PR #86. git diff origin/main...origin/pr/86'", workdir="~/project", background=true, pty=true)
            terminal(command="codex exec 'Review PR #87. git diff origin/main...origin/pr/87'", workdir="~/project", background=true, pty=true)

            # Post results
            terminal(command="gh pr comment 86 --body '<review>'", workdir="~/project")
            ```

            ## Rules

            1. **Always use `pty=true`** — Codex is an interactive terminal app and hangs without a PTY
            2. **Git repo required** — Codex won't run outside a git directory. Use `mktemp -d && git init` for scratch
            3. **Use `exec` for one-shots** — `codex exec "prompt"` runs and exits cleanly
            4. **`--full-auto` for building** — auto-approves changes within the sandbox
            5. **Background for long tasks** — use `background=true` and monitor with `process` tool
            6. **Don't interfere** — monitor with `poll`/`log`, be patient with long-running tasks
            7. **Parallel is fine** — run multiple Codex processes at once for batch work

            """#
        ),
        Entry(
            name: "excalidraw",
            description: "Hand-drawn Excalidraw JSON diagrams (arch, flow, seq).",
            body: #"""
            ---
            name: excalidraw
            description: "Hand-drawn Excalidraw JSON diagrams (arch, flow, seq)."
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            dependencies: []
            metadata:
              hermes:
                tags: [Excalidraw, Diagrams, Flowcharts, Architecture, Visualization, JSON]
                related_skills: []

            ---

            # Excalidraw Diagram Skill

            Create diagrams by writing standard Excalidraw element JSON and saving as `.excalidraw` files. These files can be drag-and-dropped onto [excalidraw.com](https://excalidraw.com) for viewing and editing. No accounts, no API keys, no rendering libraries -- just JSON.

            ## When to use

            Generate `.excalidraw` files for architecture diagrams, flowcharts, sequence diagrams, concept maps, and more. Files can be opened at excalidraw.com or uploaded for shareable links.

            ## Workflow

            1. **Load this skill** (you already did)
            2. **Write the elements JSON** -- an array of Excalidraw element objects
            3. **Save the file** using `write_file` to create a `.excalidraw` file
            4. **Optionally upload** for a shareable link using `scripts/upload.py` via `terminal`

            ### Saving a Diagram

            Wrap your elements array in the standard `.excalidraw` envelope and save with `write_file`:

            ```json
            {
              "type": "excalidraw",
              "version": 2,
              "source": "hermes-agent",
              "elements": [ ...your elements array here... ],
              "appState": {
                "viewBackgroundColor": "#ffffff"
              }
            }
            ```

            Save to any path, e.g. `~/diagrams/my_diagram.excalidraw`.

            ### Uploading for a Shareable Link

            Run the upload script (located in this skill's `scripts/` directory) via terminal:

            ```bash
            python skills/diagramming/excalidraw/scripts/upload.py ~/diagrams/my_diagram.excalidraw
            ```

            This uploads to excalidraw.com (no account needed) and prints a shareable URL. Requires the `cryptography` pip package (`pip install cryptography`).

            ---

            ## Element Format Reference

            ### Required Fields (all elements)
            `type`, `id` (unique string), `x`, `y`, `width`, `height`

            ### Defaults (skip these -- they're applied automatically)
            - `strokeColor`: `"#1e1e1e"`
            - `backgroundColor`: `"transparent"`
            - `fillStyle`: `"solid"`
            - `strokeWidth`: `2`
            - `roughness`: `1` (hand-drawn look)
            - `opacity`: `100`

            Canvas background is white.

            ### Element Types

            **Rectangle**:
            ```json
            { "type": "rectangle", "id": "r1", "x": 100, "y": 100, "width": 200, "height": 100 }
            ```
            - `roundness: { "type": 3 }` for rounded corners
            - `backgroundColor: "#a5d8ff"`, `fillStyle: "solid"` for filled

            **Ellipse**:
            ```json
            { "type": "ellipse", "id": "e1", "x": 100, "y": 100, "width": 150, "height": 150 }
            ```

            **Diamond**:
            ```json
            { "type": "diamond", "id": "d1", "x": 100, "y": 100, "width": 150, "height": 150 }
            ```

            **Labeled shape (container binding)** -- create a text element bound to the shape:

            > **WARNING:** Do NOT use `"label": { "text": "..." }` on shapes. This is NOT a valid
            > Excalidraw property and will be silently ignored, producing blank shapes. You MUST
            > use the container binding approach below.

            The shape needs `boundElements` listing the text, and the text needs `containerId` pointing back:
            ```json
            { "type": "rectangle", "id": "r1", "x": 100, "y": 100, "width": 200, "height": 80,
              "roundness": { "type": 3 }, "backgroundColor": "#a5d8ff", "fillStyle": "solid",
              "boundElements": [{ "id": "t_r1", "type": "text" }] },
            { "type": "text", "id": "t_r1", "x": 105, "y": 110, "width": 190, "height": 25,
              "text": "Hello", "fontSize": 20, "fontFamily": 1, "strokeColor": "#1e1e1e",
              "textAlign": "center", "verticalAlign": "middle",
              "containerId": "r1", "originalText": "Hello", "autoResize": true }
            ```
            - Works on rectangle, ellipse, diamond
            - Text is auto-centered by Excalidraw when `containerId` is set
            - The text `x`/`y`/`width`/`height` are approximate -- Excalidraw recalculates them on load
            - `originalText` should match `text`
            - Always include `fontFamily: 1` (Virgil/hand-drawn font)

            **Labeled arrow** -- same container binding approach:
            ```json
            { "type": "arrow", "id": "a1", "x": 300, "y": 150, "width": 200, "height": 0,
              "points": [[0,0],[200,0]], "endArrowhead": "arrow",
              "boundElements": [{ "id": "t_a1", "type": "text" }] },
            { "type": "text", "id": "t_a1", "x": 370, "y": 130, "width": 60, "height": 20,
              "text": "connects", "fontSize": 16, "fontFamily": 1, "strokeColor": "#1e1e1e",
              "textAlign": "center", "verticalAlign": "middle",
              "containerId": "a1", "originalText": "connects", "autoResize": true }
            ```

            **Standalone text** (titles and annotations only -- no container):
            ```json
            { "type": "text", "id": "t1", "x": 150, "y": 138, "text": "Hello", "fontSize": 20,
              "fontFamily": 1, "strokeColor": "#1e1e1e", "originalText": "Hello", "autoResize": true }
            ```
            - `x` is the LEFT edge. To center at position `cx`: `x = cx - (text.length * fontSize * 0.5) / 2`
            - Do NOT rely on `textAlign` or `width` for positioning

            **Arrow**:
            ```json
            { "type": "arrow", "id": "a1", "x": 300, "y": 150, "width": 200, "height": 0,
              "points": [[0,0],[200,0]], "endArrowhead": "arrow" }
            ```
            - `points`: `[dx, dy]` offsets from element `x`, `y`
            - `endArrowhead`: `null` | `"arrow"` | `"bar"` | `"dot"` | `"triangle"`
            - `strokeStyle`: `"solid"` (default) | `"dashed"` | `"dotted"`

            ### Arrow Bindings (connect arrows to shapes)

            ```json
            {
              "type": "arrow", "id": "a1", "x": 300, "y": 150, "width": 150, "height": 0,
              "points": [[0,0],[150,0]], "endArrowhead": "arrow",
              "startBinding": { "elementId": "r1", "fixedPoint": [1, 0.5] },
              "endBinding": { "elementId": "r2", "fixedPoint": [0, 0.5] }
            }
            ```

            `fixedPoint` coordinates: `top=[0.5,0]`, `bottom=[0.5,1]`, `left=[0,0.5]`, `right=[1,0.5]`

            ### Drawing Order (z-order)
            - Array order = z-order (first = back, last = front)
            - Emit progressively: background zones → shape → its bound text → its arrows → next shape
            - BAD: all rectangles, then all texts, then all arrows
            - GOOD: bg_zone → shape1 → text_for_shape1 → arrow1 → arrow_label_text → shape2 → text_for_shape2 → ...
            - Always place the bound text element immediately after its container shape

            ### Sizing Guidelines

            **Font sizes:**
            - Minimum `fontSize`: **16** for body text, labels, descriptions
            - Minimum `fontSize`: **20** for titles and headings
            - Minimum `fontSize`: **14** for secondary annotations only (sparingly)
            - NEVER use `fontSize` below 14

            **Element sizes:**
            - Minimum shape size: 120x60 for labeled rectangles/ellipses
            - Leave 20-30px gaps between elements minimum
            - Prefer fewer, larger elements over many tiny ones

            ### Color Palette

            See `references/colors.md` for full color tables. Quick reference:

            | Use | Fill Color | Hex |
            |-----|-----------|-----|
            | Primary / Input | Light Blue | `#a5d8ff` |
            | Success / Output | Light Green | `#b2f2bb` |
            | Warning / External | Light Orange | `#ffd8a8` |
            | Processing / Special | Light Purple | `#d0bfff` |
            | Error / Critical | Light Red | `#ffc9c9` |
            | Notes / Decisions | Light Yellow | `#fff3bf` |
            | Storage / Data | Light Teal | `#c3fae8` |

            ### Tips
            - Use the color palette consistently across the diagram
            - **Text contrast is CRITICAL** -- never use light gray on white backgrounds. Minimum text color on white: `#757575`
            - Do NOT use emoji in text -- they don't render in Excalidraw's font
            - For dark mode diagrams, see `references/dark-mode.md`
            - For larger examples, see `references/examples.md`

            """#
        ),
        Entry(
            name: "findmy",
            description: "Track Apple devices/AirTags via FindMy.app on macOS.",
            body: #"""
            ---
            name: findmy
            description: "Track Apple devices/AirTags via FindMy.app on macOS."
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            platforms: [macos]
            metadata:
              hermes:
                tags: [FindMy, AirTag, location, tracking, macOS, Apple]
            ---

            # Find My (Apple)

            Track Apple devices and AirTags via the FindMy.app on macOS. Since Apple doesn't
            provide a CLI for FindMy, this skill uses AppleScript to open the app and
            screen capture to read device locations.

            ## Prerequisites

            - **macOS** with Find My app and iCloud signed in
            - Devices/AirTags already registered in Find My
            - Screen Recording permission for terminal (System Settings → Privacy → Screen Recording)
            - **Optional but recommended**: Install `peekaboo` for better UI automation:
              `brew install steipete/tap/peekaboo`

            ## When to Use

            - User asks "where is my [device/cat/keys/bag]?"
            - Tracking AirTag locations
            - Checking device locations (iPhone, iPad, Mac, AirPods)
            - Monitoring pet or item movement over time (AirTag patrol routes)

            ## Method 1: AppleScript + Screenshot (Basic)

            ### Open FindMy and Navigate

            ```bash
            # Open Find My app
            osascript -e 'tell application "FindMy" to activate'

            # Wait for it to load
            sleep 3

            # Take a screenshot of the Find My window
            screencapture -w -o /tmp/findmy.png
            ```

            Then use `vision_analyze` to read the screenshot:
            ```
            vision_analyze(image_url="/tmp/findmy.png", question="What devices/items are shown and what are their locations?")
            ```

            ### Switch Between Tabs

            ```bash
            # Switch to Devices tab
            osascript -e '
            tell application "System Events"
                tell process "FindMy"
                    click button "Devices" of toolbar 1 of window 1
                end tell
            end tell'

            # Switch to Items tab (AirTags)
            osascript -e '
            tell application "System Events"
                tell process "FindMy"
                    click button "Items" of toolbar 1 of window 1
                end tell
            end tell'
            ```

            ## Method 2: Peekaboo UI Automation (Recommended)

            If `peekaboo` is installed, use it for more reliable UI interaction:

            ```bash
            # Open Find My
            osascript -e 'tell application "FindMy" to activate'
            sleep 3

            # Capture and annotate the UI
            peekaboo see --app "FindMy" --annotate --path /tmp/findmy-ui.png

            # Click on a specific device/item by element ID
            peekaboo click --on B3 --app "FindMy"

            # Capture the detail view
            peekaboo image --app "FindMy" --path /tmp/findmy-detail.png
            ```

            Then analyze with vision:
            ```
            vision_analyze(image_url="/tmp/findmy-detail.png", question="What is the location shown for this device/item? Include address and coordinates if visible.")
            ```

            ## Workflow: Track AirTag Location Over Time

            For monitoring an AirTag (e.g., tracking a cat's patrol route):

            ```bash
            # 1. Open FindMy to Items tab
            osascript -e 'tell application "FindMy" to activate'
            sleep 3

            # 2. Click on the AirTag item (stay on page — AirTag only updates when page is open)

            # 3. Periodically capture location
            while true; do
                screencapture -w -o /tmp/findmy-$(date +%H%M%S).png
                sleep 300  # Every 5 minutes
            done
            ```

            Analyze each screenshot with vision to extract coordinates, then compile a route.

            ## Limitations

            - FindMy has **no CLI or API** — must use UI automation
            - AirTags only update location while the FindMy page is actively displayed
            - Location accuracy depends on nearby Apple devices in the FindMy network
            - Screen Recording permission required for screenshots
            - AppleScript UI automation may break across macOS versions

            ## Rules

            1. Keep FindMy app in the foreground when tracking AirTags (updates stop when minimized)
            2. Use `vision_analyze` to read screenshot content — don't try to parse pixels
            3. For ongoing tracking, use a cronjob to periodically capture and log locations
            4. Respect privacy — only track devices/items the user owns

            """#
        ),
        Entry(
            name: "github-auth",
            description: "GitHub auth setup: HTTPS tokens, SSH keys, gh CLI login.",
            body: #"""
            ---
            name: github-auth
            description: "GitHub auth setup: HTTPS tokens, SSH keys, gh CLI login."
            version: 1.1.0
            author: Hermes Agent
            license: MIT
            metadata:
              hermes:
                tags: [GitHub, Authentication, Git, gh-cli, SSH, Setup]
                related_skills: [github-pr-workflow, github-code-review, github-issues, github-repo-management]
            ---

            # GitHub Authentication Setup

            This skill sets up authentication so the agent can work with GitHub repositories, PRs, issues, and CI. It covers two paths:

            - **`git` (always available)** — uses HTTPS personal access tokens or SSH keys
            - **`gh` CLI (if installed)** — richer GitHub API access with a simpler auth flow

            ## Detection Flow

            When a user asks you to work with GitHub, run this check first:

            ```bash
            # Check what's available
            git --version
            gh --version 2>/dev/null || echo "gh not installed"

            # Check if already authenticated
            gh auth status 2>/dev/null || echo "gh not authenticated"
            git config --global credential.helper 2>/dev/null || echo "no git credential helper"
            ```

            **Decision tree:**
            1. If `gh auth status` shows authenticated → you're good, use `gh` for everything
            2. If `gh` is installed but not authenticated → use "gh auth" method below
            3. If `gh` is not installed → use "git-only" method below (no sudo needed)

            ---

            ## Method 1: Git-Only Authentication (No gh, No sudo)

            This works on any machine with `git` installed. No root access needed.

            ### Option A: HTTPS with Personal Access Token (Recommended)

            This is the most portable method — works everywhere, no SSH config needed.

            **Step 1: Create a personal access token**

            Tell the user to go to: **https://github.com/settings/tokens**

            - Click "Generate new token (classic)"
            - Give it a name like "hermes-agent"
            - Select scopes:
              - `repo` (full repository access — read, write, push, PRs)
              - `workflow` (trigger and manage GitHub Actions)
              - `read:org` (if working with organization repos)
            - Set expiration (90 days is a good default)
            - Copy the token — it won't be shown again

            **Step 2: Configure git to store the token**

            ```bash
            # Set up the credential helper to cache credentials
            # "store" saves to ~/.git-credentials in plaintext (simple, persistent)
            git config --global credential.helper store

            # Now do a test operation that triggers auth — git will prompt for credentials
            # Username: <their-github-username>
            # Password: <paste the personal access token, NOT their GitHub password>
            git ls-remote https://github.com/<their-username>/<any-repo>.git
            ```

            After entering credentials once, they're saved and reused for all future operations.

            **Alternative: cache helper (credentials expire from memory)**

            ```bash
            # Cache in memory for 8 hours (28800 seconds) instead of saving to disk
            git config --global credential.helper 'cache --timeout=28800'
            ```

            **Alternative: set the token directly in the remote URL (per-repo)**

            ```bash
            # Embed token in the remote URL (avoids credential prompts entirely)
            git remote set-url origin https://<username>:<token>@github.com/<owner>/<repo>.git
            ```

            **Step 3: Configure git identity**

            ```bash
            # Required for commits — set name and email
            git config --global user.name "Their Name"
            git config --global user.email "their-email@example.com"
            ```

            **Step 4: Verify**

            ```bash
            # Test push access (this should work without any prompts now)
            git ls-remote https://github.com/<their-username>/<any-repo>.git

            # Verify identity
            git config --global user.name
            git config --global user.email
            ```

            ### Option B: SSH Key Authentication

            Good for users who prefer SSH or already have keys set up.

            **Step 1: Check for existing SSH keys**

            ```bash
            ls -la ~/.ssh/id_*.pub 2>/dev/null || echo "No SSH keys found"
            ```

            **Step 2: Generate a key if needed**

            ```bash
            # Generate an ed25519 key (modern, secure, fast)
            ssh-keygen -t ed25519 -C "their-email@example.com" -f ~/.ssh/id_ed25519 -N ""

            # Display the public key for them to add to GitHub
            cat ~/.ssh/id_ed25519.pub
            ```

            Tell the user to add the public key at: **https://github.com/settings/keys**
            - Click "New SSH key"
            - Paste the public key content
            - Give it a title like "hermes-agent-<machine-name>"

            **Step 3: Test the connection**

            ```bash
            ssh -T git@github.com
            # Expected: "Hi <username>! You've successfully authenticated..."
            ```

            **Step 4: Configure git to use SSH for GitHub**

            ```bash
            # Rewrite HTTPS GitHub URLs to SSH automatically
            git config --global url."git@github.com:".insteadOf "https://github.com/"
            ```

            **Step 5: Configure git identity**

            ```bash
            git config --global user.name "Their Name"
            git config --global user.email "their-email@example.com"
            ```

            ---

            ## Method 2: gh CLI Authentication

            If `gh` is installed, it handles both API access and git credentials in one step.

            ### Interactive Browser Login (Desktop)

            ```bash
            gh auth login
            # Select: GitHub.com
            # Select: HTTPS
            # Authenticate via browser
            ```

            ### Token-Based Login (Headless / SSH Servers)

            ```bash
            echo "<THEIR_TOKEN>" | gh auth login --with-token

            # Set up git credentials through gh
            gh auth setup-git
            ```

            ### Verify

            ```bash
            gh auth status
            ```

            ---

            ## Using the GitHub API Without gh

            When `gh` is not available, you can still access the full GitHub API using `curl` with a personal access token. This is how the other GitHub skills implement their fallbacks.

            ### Setting the Token for API Calls

            ```bash
            # Option 1: Export as env var (preferred — keeps it out of commands)
            export GITHUB_TOKEN="<token>"

            # Then use in curl calls:
            curl -s -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/user
            ```

            ### Extracting the Token from Git Credentials

            If git credentials are already configured (via credential.helper store), the token can be extracted:

            ```bash
            # Read from git credential store
            grep "github.com" ~/.git-credentials 2>/dev/null | head -1 | sed 's|https://[^:]*:\([^@]*\)@.*|\1|'
            ```

            ### Helper: Detect Auth Method

            Use this pattern at the start of any GitHub workflow:

            ```bash
            # Try gh first, fall back to git + curl
            if command -v gh &>/dev/null && gh auth status &>/dev/null; then
              echo "AUTH_METHOD=gh"
            elif [ -n "$GITHUB_TOKEN" ]; then
              echo "AUTH_METHOD=curl"
            elif [ -f ~/.hermes/.env ] && grep -q "^GITHUB_TOKEN=" ~/.hermes/.env; then
              export GITHUB_TOKEN=$(grep "^GITHUB_TOKEN=" ~/.hermes/.env | head -1 | cut -d= -f2 | tr -d '\n\r')
              echo "AUTH_METHOD=curl"
            elif grep -q "github.com" ~/.git-credentials 2>/dev/null; then
              export GITHUB_TOKEN=$(grep "github.com" ~/.git-credentials | head -1 | sed 's|https://[^:]*:\([^@]*\)@.*|\1|')
              echo "AUTH_METHOD=curl"
            else
              echo "AUTH_METHOD=none"
              echo "Need to set up authentication first"
            fi
            ```

            ---

            ## Troubleshooting

            | Problem | Solution |
            |---------|----------|
            | `git push` asks for password | GitHub disabled password auth. Use a personal access token as the password, or switch to SSH |
            | `remote: Permission to X denied` | Token may lack `repo` scope — regenerate with correct scopes |
            | `fatal: Authentication failed` | Cached credentials may be stale — run `git credential reject` then re-authenticate |
            | `ssh: connect to host github.com port 22: Connection refused` | Try SSH over HTTPS port: add `Host github.com` with `Port 443` and `Hostname ssh.github.com` to `~/.ssh/config` |
            | Credentials not persisting | Check `git config --global credential.helper` — must be `store` or `cache` |
            | Multiple GitHub accounts | Use SSH with different keys per host alias in `~/.ssh/config`, or per-repo credential URLs |
            | `gh: command not found` + no sudo | Use git-only Method 1 above — no installation needed |

            """#
        ),
        Entry(
            name: "github-code-review",
            description: "Review PRs: diffs, inline comments via gh or REST.",
            body: #"""
            ---
            name: github-code-review
            description: "Review PRs: diffs, inline comments via gh or REST."
            version: 1.1.0
            author: Hermes Agent
            license: MIT
            metadata:
              hermes:
                tags: [GitHub, Code-Review, Pull-Requests, Git, Quality]
                related_skills: [github-auth, github-pr-workflow]
            ---

            # GitHub Code Review

            Perform code reviews on local changes before pushing, or review open PRs on GitHub. Most of this skill uses plain `git` — the `gh`/`curl` split only matters for PR-level interactions.

            ## Prerequisites

            - Authenticated with GitHub (see `github-auth` skill)
            - Inside a git repository

            ### Setup (for PR interactions)

            ```bash
            if command -v gh &>/dev/null && gh auth status &>/dev/null; then
              AUTH="gh"
            else
              AUTH="git"
              if [ -z "$GITHUB_TOKEN" ]; then
                if [ -f ~/.hermes/.env ] && grep -q "^GITHUB_TOKEN=" ~/.hermes/.env; then
                  GITHUB_TOKEN=$(grep "^GITHUB_TOKEN=" ~/.hermes/.env | head -1 | cut -d= -f2 | tr -d '\n\r')
                elif grep -q "github.com" ~/.git-credentials 2>/dev/null; then
                  GITHUB_TOKEN=$(grep "github.com" ~/.git-credentials 2>/dev/null | head -1 | sed 's|https://[^:]*:\([^@]*\)@.*|\1|')
                fi
              fi
            fi

            REMOTE_URL=$(git remote get-url origin)
            OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
            OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
            REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
            ```

            ---

            ## 1. Reviewing Local Changes (Pre-Push)

            This is pure `git` — works everywhere, no API needed.

            ### Get the Diff

            ```bash
            # Staged changes (what would be committed)
            git diff --staged

            # All changes vs main (what a PR would contain)
            git diff main...HEAD

            # File names only
            git diff main...HEAD --name-only

            # Stat summary (insertions/deletions per file)
            git diff main...HEAD --stat
            ```

            ### Review Strategy

            1. **Get the big picture first:**

            ```bash
            git diff main...HEAD --stat
            git log main..HEAD --oneline
            ```

            2. **Review file by file** — use `read_file` on changed files for full context, and the diff to see what changed:

            ```bash
            git diff main...HEAD -- src/auth/login.py
            ```

            3. **Check for common issues:**

            ```bash
            # Debug statements, TODOs, console.logs left behind
            git diff main...HEAD | grep -n "print(\|console\.log\|TODO\|FIXME\|HACK\|XXX\|debugger"

            # Large files accidentally staged
            git diff main...HEAD --stat | sort -t'|' -k2 -rn | head -10

            # Secrets or credential patterns
            git diff main...HEAD | grep -in "password\|secret\|api_key\|token.*=\|private_key"

            # Merge conflict markers
            git diff main...HEAD | grep -n "<<<<<<\|>>>>>>\|======="
            ```

            4. **Present structured feedback** to the user.

            ### Review Output Format

            When reviewing local changes, present findings in this structure:

            ```
            ## Code Review Summary

            ### Critical
            - **src/auth.py:45** — SQL injection: user input passed directly to query.
              Suggestion: Use parameterized queries.

            ### Warnings
            - **src/models/user.py:23** — Password stored in plaintext. Use bcrypt or argon2.
            - **src/api/routes.py:112** — No rate limiting on login endpoint.

            ### Suggestions
            - **src/utils/helpers.py:8** — Duplicates logic in `src/core/utils.py:34`. Consolidate.
            - **tests/test_auth.py** — Missing edge case: expired token test.

            ### Looks Good
            - Clean separation of concerns in the middleware layer
            - Good test coverage for the happy path
            ```

            ---

            ## 2. Reviewing a Pull Request on GitHub

            ### View PR Details

            **With gh:**

            ```bash
            gh pr view 123
            gh pr diff 123
            gh pr diff 123 --name-only
            ```

            **With git + curl:**

            ```bash
            PR_NUMBER=123

            # Get PR details
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER \
              | python3 -c "
            import sys, json
            pr = json.load(sys.stdin)
            print(f\"Title: {pr['title']}\")
            print(f\"Author: {pr['user']['login']}\")
            print(f\"Branch: {pr['head']['ref']} -> {pr['base']['ref']}\")
            print(f\"State: {pr['state']}\")
            print(f\"Body:\n{pr['body']}\")"

            # List changed files
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/files \
              | python3 -c "
            import sys, json
            for f in json.load(sys.stdin):
                print(f\"{f['status']:10} +{f['additions']:-4} -{f['deletions']:-4}  {f['filename']}\")"
            ```

            ### Check Out PR Locally for Full Review

            This works with plain `git` — no `gh` needed:

            ```bash
            # Fetch the PR branch and check it out
            git fetch origin pull/123/head:pr-123
            git checkout pr-123

            # Now you can use read_file, search_files, run tests, etc.

            # View diff against the base branch
            git diff main...pr-123
            ```

            **With gh (shortcut):**

            ```bash
            gh pr checkout 123
            ```

            ### Leave Comments on a PR

            **General PR comment — with gh:**

            ```bash
            gh pr comment 123 --body "Overall looks good, a few suggestions below."
            ```

            **General PR comment — with curl:**

            ```bash
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
              -d '{"body": "Overall looks good, a few suggestions below."}'
            ```

            ### Leave Inline Review Comments

            **Single inline comment — with gh (via API):**

            ```bash
            HEAD_SHA=$(gh pr view 123 --json headRefOid --jq '.headRefOid')

            gh api repos/$OWNER/$REPO/pulls/123/comments \
              --method POST \
              -f body="This could be simplified with a list comprehension." \
              -f path="src/auth/login.py" \
              -f commit_id="$HEAD_SHA" \
              -f line=45 \
              -f side="RIGHT"
            ```

            **Single inline comment — with curl:**

            ```bash
            # Get the head commit SHA
            HEAD_SHA=$(curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['sha'])")

            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments \
              -d "{
                \"body\": \"This could be simplified with a list comprehension.\",
                \"path\": \"src/auth/login.py\",
                \"commit_id\": \"$HEAD_SHA\",
                \"line\": 45,
                \"side\": \"RIGHT\"
              }"
            ```

            ### Submit a Formal Review (Approve / Request Changes)

            **With gh:**

            ```bash
            gh pr review 123 --approve --body "LGTM!"
            gh pr review 123 --request-changes --body "See inline comments."
            gh pr review 123 --comment --body "Some suggestions, nothing blocking."
            ```

            **With curl — multi-comment review submitted atomically:**

            ```bash
            HEAD_SHA=$(curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['sha'])")

            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews \
              -d "{
                \"commit_id\": \"$HEAD_SHA\",
                \"event\": \"COMMENT\",
                \"body\": \"Code review from Hermes Agent\",
                \"comments\": [
                  {\"path\": \"src/auth.py\", \"line\": 45, \"body\": \"Use parameterized queries to prevent SQL injection.\"},
                  {\"path\": \"src/models/user.py\", \"line\": 23, \"body\": \"Hash passwords with bcrypt before storing.\"},
                  {\"path\": \"tests/test_auth.py\", \"line\": 1, \"body\": \"Add test for expired token edge case.\"}
                ]
              }"
            ```

            Event values: `"APPROVE"`, `"REQUEST_CHANGES"`, `"COMMENT"`

            The `line` field refers to the line number in the *new* version of the file. For deleted lines, use `"side": "LEFT"`.

            ---

            ## 3. Review Checklist

            When performing a code review (local or PR), systematically check:

            ### Correctness
            - Does the code do what it claims?
            - Edge cases handled (empty inputs, nulls, large data, concurrent access)?
            - Error paths handled gracefully?

            ### Security
            - No hardcoded secrets, credentials, or API keys
            - Input validation on user-facing inputs
            - No SQL injection, XSS, or path traversal
            - Auth/authz checks where needed

            ### Code Quality
            - Clear naming (variables, functions, classes)
            - No unnecessary complexity or premature abstraction
            - DRY — no duplicated logic that should be extracted
            - Functions are focused (single responsibility)

            ### Testing
            - New code paths tested?
            - Happy path and error cases covered?
            - Tests readable and maintainable?

            ### Performance
            - No N+1 queries or unnecessary loops
            - Appropriate caching where beneficial
            - No blocking operations in async code paths

            ### Documentation
            - Public APIs documented
            - Non-obvious logic has comments explaining "why"
            - README updated if behavior changed

            ---

            ## 4. Pre-Push Review Workflow

            When the user asks you to "review the code" or "check before pushing":

            1. `git diff main...HEAD --stat` — see scope of changes
            2. `git diff main...HEAD` — read the full diff
            3. For each changed file, use `read_file` if you need more context
            4. Apply the checklist above
            5. Present findings in the structured format (Critical / Warnings / Suggestions / Looks Good)
            6. If critical issues found, offer to fix them before the user pushes

            ---

            ## 5. PR Review Workflow (End-to-End)

            When the user asks you to "review PR #N", "look at this PR", or gives you a PR URL, follow this recipe:

            ### Step 1: Set up environment

            ```bash
            source "${HERMES_HOME:-$HOME/.hermes}/skills/github/github-auth/scripts/gh-env.sh"
            # Or run the inline setup block from the top of this skill
            ```

            ### Step 2: Gather PR context

            Get the PR metadata, description, and list of changed files to understand scope before diving into code.

            **With gh:**
            ```bash
            gh pr view 123
            gh pr diff 123 --name-only
            gh pr checks 123
            ```

            **With curl:**
            ```bash
            PR_NUMBER=123

            # PR details (title, author, description, branch)
            curl -s -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$GH_OWNER/$GH_REPO/pulls/$PR_NUMBER

            # Changed files with line counts
            curl -s -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$GH_OWNER/$GH_REPO/pulls/$PR_NUMBER/files
            ```

            ### Step 3: Check out the PR locally

            This gives you full access to `read_file`, `search_files`, and the ability to run tests.

            ```bash
            git fetch origin pull/$PR_NUMBER/head:pr-$PR_NUMBER
            git checkout pr-$PR_NUMBER
            ```

            ### Step 4: Read the diff and understand changes

            ```bash
            # Full diff against the base branch
            git diff main...HEAD

            # Or file-by-file for large PRs
            git diff main...HEAD --name-only
            # Then for each file:
            git diff main...HEAD -- path/to/file.py
            ```

            For each changed file, use `read_file` to see full context around the changes — diffs alone can miss issues visible only with surrounding code.

            ### Step 5: Run automated checks locally (if applicable)

            ```bash
            # Run tests if there's a test suite
            python -m pytest 2>&1 | tail -20
            # or: npm test, cargo test, go test ./..., etc.

            # Run linter if configured
            ruff check . 2>&1 | head -30
            # or: eslint, clippy, etc.
            ```

            ### Step 6: Apply the review checklist (Section 3)

            Go through each category: Correctness, Security, Code Quality, Testing, Performance, Documentation.

            ### Step 7: Post the review to GitHub

            Collect your findings and submit them as a formal review with inline comments.

            **With gh:**
            ```bash
            # If no issues — approve
            gh pr review $PR_NUMBER --approve --body "Reviewed by Hermes Agent. Code looks clean — good test coverage, no security concerns."

            # If issues found — request changes with inline comments
            gh pr review $PR_NUMBER --request-changes --body "Found a few issues — see inline comments."
            ```

            **With curl — atomic review with multiple inline comments:**
            ```bash
            HEAD_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$GH_OWNER/$GH_REPO/pulls/$PR_NUMBER \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['sha'])")

            # Build the review JSON — event is APPROVE, REQUEST_CHANGES, or COMMENT
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$GH_OWNER/$GH_REPO/pulls/$PR_NUMBER/reviews \
              -d "{
                \"commit_id\": \"$HEAD_SHA\",
                \"event\": \"REQUEST_CHANGES\",
                \"body\": \"## Hermes Agent Review\n\nFound 2 issues, 1 suggestion. See inline comments.\",
                \"comments\": [
                  {\"path\": \"src/auth.py\", \"line\": 45, \"body\": \"🔴 **Critical:** User input passed directly to SQL query — use parameterized queries.\"},
                  {\"path\": \"src/models.py\", \"line\": 23, \"body\": \"⚠️ **Warning:** Password stored without hashing.\"},
                  {\"path\": \"src/utils.py\", \"line\": 8, \"body\": \"💡 **Suggestion:** This duplicates logic in core/utils.py:34.\"}
                ]
              }"
            ```

            ### Step 8: Also post a summary comment

            In addition to inline comments, leave a top-level summary so the PR author gets the full picture at a glance. Use the review output format from `references/review-output-template.md`.

            **With gh:**
            ```bash
            gh pr comment $PR_NUMBER --body "$(cat <<'EOF'
            ## Code Review Summary

            **Verdict: Changes Requested** (2 issues, 1 suggestion)

            ### 🔴 Critical
            - **src/auth.py:45** — SQL injection vulnerability

            ### ⚠️ Warnings
            - **src/models.py:23** — Plaintext password storage

            ### 💡 Suggestions
            - **src/utils.py:8** — Duplicated logic, consider consolidating

            ### ✅ Looks Good
            - Clean API design
            - Good error handling in the middleware layer

            ---
            *Reviewed by Hermes Agent*
            EOF
            )"
            ```

            ### Step 9: Clean up

            ```bash
            git checkout main
            git branch -D pr-$PR_NUMBER
            ```

            ### Decision: Approve vs Request Changes vs Comment

            - **Approve** — no critical or warning-level issues, only minor suggestions or all clear
            - **Request Changes** — any critical or warning-level issue that should be fixed before merge
            - **Comment** — observations and suggestions, but nothing blocking (use when you're unsure or the PR is a draft)

            """#
        ),
        Entry(
            name: "github-issues",
            description: "Create, triage, label, assign GitHub issues via gh or REST.",
            body: #"""
            ---
            name: github-issues
            description: "Create, triage, label, assign GitHub issues via gh or REST."
            version: 1.1.0
            author: Hermes Agent
            license: MIT
            metadata:
              hermes:
                tags: [GitHub, Issues, Project-Management, Bug-Tracking, Triage]
                related_skills: [github-auth, github-pr-workflow]
            ---

            # GitHub Issues Management

            Create, search, triage, and manage GitHub issues. Each section shows `gh` first, then the `curl` fallback.

            ## Prerequisites

            - Authenticated with GitHub (see `github-auth` skill)
            - Inside a git repo with a GitHub remote, or specify the repo explicitly

            ### Setup

            ```bash
            if command -v gh &>/dev/null && gh auth status &>/dev/null; then
              AUTH="gh"
            else
              AUTH="git"
              if [ -z "$GITHUB_TOKEN" ]; then
                if [ -f ~/.hermes/.env ] && grep -q "^GITHUB_TOKEN=" ~/.hermes/.env; then
                  GITHUB_TOKEN=$(grep "^GITHUB_TOKEN=" ~/.hermes/.env | head -1 | cut -d= -f2 | tr -d '\n\r')
                elif grep -q "github.com" ~/.git-credentials 2>/dev/null; then
                  GITHUB_TOKEN=$(grep "github.com" ~/.git-credentials 2>/dev/null | head -1 | sed 's|https://[^:]*:\([^@]*\)@.*|\1|')
                fi
              fi
            fi

            REMOTE_URL=$(git remote get-url origin)
            OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
            OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
            REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
            ```

            ---

            ## 1. Viewing Issues

            **With gh:**

            ```bash
            gh issue list
            gh issue list --state open --label "bug"
            gh issue list --assignee @me
            gh issue list --search "authentication error" --state all
            gh issue view 42
            ```

            **With curl:**

            ```bash
            # List open issues
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/repos/$OWNER/$REPO/issues?state=open&per_page=20" \
              | python3 -c "
            import sys, json
            for i in json.load(sys.stdin):
                if 'pull_request' not in i:  # GitHub API returns PRs in /issues too
                    labels = ', '.join(l['name'] for l in i['labels'])
                    print(f\"#{i['number']:5}  {i['state']:6}  {labels:30}  {i['title']}\")"

            # Filter by label
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/repos/$OWNER/$REPO/issues?state=open&labels=bug&per_page=20" \
              | python3 -c "
            import sys, json
            for i in json.load(sys.stdin):
                if 'pull_request' not in i:
                    print(f\"#{i['number']}  {i['title']}\")"

            # View a specific issue
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/42 \
              | python3 -c "
            import sys, json
            i = json.load(sys.stdin)
            labels = ', '.join(l['name'] for l in i['labels'])
            assignees = ', '.join(a['login'] for a in i['assignees'])
            print(f\"#{i['number']}: {i['title']}\")
            print(f\"State: {i['state']}  Labels: {labels}  Assignees: {assignees}\")
            print(f\"Author: {i['user']['login']}  Created: {i['created_at']}\")
            print(f\"\n{i['body']}\")"

            # Search issues
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/search/issues?q=authentication+error+repo:$OWNER/$REPO" \
              | python3 -c "
            import sys, json
            for i in json.load(sys.stdin)['items']:
                print(f\"#{i['number']}  {i['state']:6}  {i['title']}\")"
            ```

            ## 2. Creating Issues

            **With gh:**

            ```bash
            gh issue create \
              --title "Login redirect ignores ?next= parameter" \
              --body "## Description
            After logging in, users always land on /dashboard.

            ## Steps to Reproduce
            1. Navigate to /settings while logged out
            2. Get redirected to /login?next=/settings
            3. Log in
            4. Actual: redirected to /dashboard (should go to /settings)

            ## Expected Behavior
            Respect the ?next= query parameter." \
              --label "bug,backend" \
              --assignee "username"
            ```

            **With curl:**

            ```bash
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues \
              -d '{
                "title": "Login redirect ignores ?next= parameter",
                "body": "## Description\nAfter logging in, users always land on /dashboard.\n\n## Steps to Reproduce\n1. Navigate to /settings while logged out\n2. Get redirected to /login?next=/settings\n3. Log in\n4. Actual: redirected to /dashboard\n\n## Expected Behavior\nRespect the ?next= query parameter.",
                "labels": ["bug", "backend"],
                "assignees": ["username"]
              }'
            ```

            ### Bug Report Template

            ```
            ## Bug Description
            <What's happening>

            ## Steps to Reproduce
            1. <step>
            2. <step>

            ## Expected Behavior
            <What should happen>

            ## Actual Behavior
            <What actually happens>

            ## Environment
            - OS: <os>
            - Version: <version>
            ```

            ### Feature Request Template

            ```
            ## Feature Description
            <What you want>

            ## Motivation
            <Why this would be useful>

            ## Proposed Solution
            <How it could work>

            ## Alternatives Considered
            <Other approaches>
            ```

            ## 3. Managing Issues

            ### Add/Remove Labels

            **With gh:**

            ```bash
            gh issue edit 42 --add-label "priority:high,bug"
            gh issue edit 42 --remove-label "needs-triage"
            ```

            **With curl:**

            ```bash
            # Add labels
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/42/labels \
              -d '{"labels": ["priority:high", "bug"]}'

            # Remove a label
            curl -s -X DELETE \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/42/labels/needs-triage

            # List available labels in the repo
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/labels \
              | python3 -c "
            import sys, json
            for l in json.load(sys.stdin):
                print(f\"  {l['name']:30}  {l.get('description', '')}\")"
            ```

            ### Assignment

            **With gh:**

            ```bash
            gh issue edit 42 --add-assignee username
            gh issue edit 42 --add-assignee @me
            ```

            **With curl:**

            ```bash
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/42/assignees \
              -d '{"assignees": ["username"]}'
            ```

            ### Commenting

            **With gh:**

            ```bash
            gh issue comment 42 --body "Investigated — root cause is in auth middleware. Working on a fix."
            ```

            **With curl:**

            ```bash
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/42/comments \
              -d '{"body": "Investigated — root cause is in auth middleware. Working on a fix."}'
            ```

            ### Closing and Reopening

            **With gh:**

            ```bash
            gh issue close 42
            gh issue close 42 --reason "not planned"
            gh issue reopen 42
            ```

            **With curl:**

            ```bash
            # Close
            curl -s -X PATCH \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/42 \
              -d '{"state": "closed", "state_reason": "completed"}'

            # Reopen
            curl -s -X PATCH \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/issues/42 \
              -d '{"state": "open"}'
            ```

            ### Linking Issues to PRs

            Issues are automatically closed when a PR merges with the right keywords in the body:

            ```
            Closes #42
            Fixes #42
            Resolves #42
            ```

            To create a branch from an issue:

            **With gh:**

            ```bash
            gh issue develop 42 --checkout
            ```

            **With git (manual equivalent):**

            ```bash
            git checkout main && git pull origin main
            git checkout -b fix/issue-42-login-redirect
            ```

            ## 4. Issue Triage Workflow

            When asked to triage issues:

            1. **List untriaged issues:**

            ```bash
            # With gh
            gh issue list --label "needs-triage" --state open

            # With curl
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/repos/$OWNER/$REPO/issues?labels=needs-triage&state=open" \
              | python3 -c "
            import sys, json
            for i in json.load(sys.stdin):
                if 'pull_request' not in i:
                    print(f\"#{i['number']}  {i['title']}\")"
            ```

            2. **Read and categorize** each issue (view details, understand the bug/feature)

            3. **Apply labels and priority** (see Managing Issues above)

            4. **Assign** if the owner is clear

            5. **Comment with triage notes** if needed

            ## 5. Bulk Operations

            For batch operations, combine API calls with shell scripting:

            **With gh:**

            ```bash
            # Close all issues with a specific label
            gh issue list --label "wontfix" --json number --jq '.[].number' | \
              xargs -I {} gh issue close {} --reason "not planned"
            ```

            **With curl:**

            ```bash
            # List issue numbers with a label, then close each
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/repos/$OWNER/$REPO/issues?labels=wontfix&state=open" \
              | python3 -c "import sys,json; [print(i['number']) for i in json.load(sys.stdin)]" \
              | while read num; do
                curl -s -X PATCH \
                  -H "Authorization: token $GITHUB_TOKEN" \
                  https://api.github.com/repos/$OWNER/$REPO/issues/$num \
                  -d '{"state": "closed", "state_reason": "not_planned"}'
                echo "Closed #$num"
              done
            ```

            ## Quick Reference Table

            | Action | gh | curl endpoint |
            |--------|-----|--------------|
            | List issues | `gh issue list` | `GET /repos/{o}/{r}/issues` |
            | View issue | `gh issue view N` | `GET /repos/{o}/{r}/issues/N` |
            | Create issue | `gh issue create ...` | `POST /repos/{o}/{r}/issues` |
            | Add labels | `gh issue edit N --add-label ...` | `POST /repos/{o}/{r}/issues/N/labels` |
            | Assign | `gh issue edit N --add-assignee ...` | `POST /repos/{o}/{r}/issues/N/assignees` |
            | Comment | `gh issue comment N --body ...` | `POST /repos/{o}/{r}/issues/N/comments` |
            | Close | `gh issue close N` | `PATCH /repos/{o}/{r}/issues/N` |
            | Search | `gh issue list --search "..."` | `GET /search/issues?q=...` |

            """#
        ),
        Entry(
            name: "github-pr-workflow",
            description: "GitHub PR lifecycle: branch, commit, open, CI, merge.",
            body: #"""
            ---
            name: github-pr-workflow
            description: "GitHub PR lifecycle: branch, commit, open, CI, merge."
            version: 1.1.0
            author: Hermes Agent
            license: MIT
            metadata:
              hermes:
                tags: [GitHub, Pull-Requests, CI/CD, Git, Automation, Merge]
                related_skills: [github-auth, github-code-review]
            ---

            # GitHub Pull Request Workflow

            Complete guide for managing the PR lifecycle. Each section shows the `gh` way first, then the `git` + `curl` fallback for machines without `gh`.

            ## Prerequisites

            - Authenticated with GitHub (see `github-auth` skill)
            - Inside a git repository with a GitHub remote

            ### Quick Auth Detection

            ```bash
            # Determine which method to use throughout this workflow
            if command -v gh &>/dev/null && gh auth status &>/dev/null; then
              AUTH="gh"
            else
              AUTH="git"
              # Ensure we have a token for API calls
              if [ -z "$GITHUB_TOKEN" ]; then
                if [ -f ~/.hermes/.env ] && grep -q "^GITHUB_TOKEN=" ~/.hermes/.env; then
                  GITHUB_TOKEN=$(grep "^GITHUB_TOKEN=" ~/.hermes/.env | head -1 | cut -d= -f2 | tr -d '\n\r')
                elif grep -q "github.com" ~/.git-credentials 2>/dev/null; then
                  GITHUB_TOKEN=$(grep "github.com" ~/.git-credentials 2>/dev/null | head -1 | sed 's|https://[^:]*:\([^@]*\)@.*|\1|')
                fi
              fi
            fi
            echo "Using: $AUTH"
            ```

            ### Extracting Owner/Repo from the Git Remote

            Many `curl` commands need `owner/repo`. Extract it from the git remote:

            ```bash
            # Works for both HTTPS and SSH remote URLs
            REMOTE_URL=$(git remote get-url origin)
            OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
            OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
            REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
            echo "Owner: $OWNER, Repo: $REPO"
            ```

            ---

            ## 1. Branch Creation

            This part is pure `git` — identical either way:

            ```bash
            # Make sure you're up to date
            git fetch origin
            git checkout main && git pull origin main

            # Create and switch to a new branch
            git checkout -b feat/add-user-authentication
            ```

            Branch naming conventions:
            - `feat/description` — new features
            - `fix/description` — bug fixes
            - `refactor/description` — code restructuring
            - `docs/description` — documentation
            - `ci/description` — CI/CD changes

            ## 2. Making Commits

            Use the agent's file tools (`write_file`, `patch`) to make changes, then commit:

            ```bash
            # Stage specific files
            git add src/auth.py src/models/user.py tests/test_auth.py

            # Commit with a conventional commit message
            git commit -m "feat: add JWT-based user authentication

            - Add login/register endpoints
            - Add User model with password hashing
            - Add auth middleware for protected routes
            - Add unit tests for auth flow"
            ```

            Commit message format (Conventional Commits):
            ```
            type(scope): short description

            Longer explanation if needed. Wrap at 72 characters.
            ```

            Types: `feat`, `fix`, `refactor`, `docs`, `test`, `ci`, `chore`, `perf`

            ## 3. Pushing and Creating a PR

            ### Push the Branch (same either way)

            ```bash
            git push -u origin HEAD
            ```

            ### Create the PR

            **With gh:**

            ```bash
            gh pr create \
              --title "feat: add JWT-based user authentication" \
              --body "## Summary
            - Adds login and register API endpoints
            - JWT token generation and validation

            ## Test Plan
            - [ ] Unit tests pass

            Closes #42"
            ```

            Options: `--draft`, `--reviewer user1,user2`, `--label "enhancement"`, `--base develop`

            **With git + curl:**

            ```bash
            BRANCH=$(git branch --show-current)

            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              -H "Accept: application/vnd.github.v3+json" \
              https://api.github.com/repos/$OWNER/$REPO/pulls \
              -d "{
                \"title\": \"feat: add JWT-based user authentication\",
                \"body\": \"## Summary\nAdds login and register API endpoints.\n\nCloses #42\",
                \"head\": \"$BRANCH\",
                \"base\": \"main\"
              }"
            ```

            The response JSON includes the PR `number` — save it for later commands.

            To create as a draft, add `"draft": true` to the JSON body.

            ## 4. Monitoring CI Status

            ### Check CI Status

            **With gh:**

            ```bash
            # One-shot check
            gh pr checks

            # Watch until all checks finish (polls every 10s)
            gh pr checks --watch
            ```

            **With git + curl:**

            ```bash
            # Get the latest commit SHA on the current branch
            SHA=$(git rev-parse HEAD)

            # Query the combined status
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/commits/$SHA/status \
              | python3 -c "
            import sys, json
            data = json.load(sys.stdin)
            print(f\"Overall: {data['state']}\")
            for s in data.get('statuses', []):
                print(f\"  {s['context']}: {s['state']} - {s.get('description', '')}\")"

            # Also check GitHub Actions check runs (separate endpoint)
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/commits/$SHA/check-runs \
              | python3 -c "
            import sys, json
            data = json.load(sys.stdin)
            for cr in data.get('check_runs', []):
                print(f\"  {cr['name']}: {cr['status']} / {cr['conclusion'] or 'pending'}\")"
            ```

            ### Poll Until Complete (git + curl)

            ```bash
            # Simple polling loop — check every 30 seconds, up to 10 minutes
            SHA=$(git rev-parse HEAD)
            for i in $(seq 1 20); do
              STATUS=$(curl -s \
                -H "Authorization: token $GITHUB_TOKEN" \
                https://api.github.com/repos/$OWNER/$REPO/commits/$SHA/status \
                | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
              echo "Check $i: $STATUS"
              if [ "$STATUS" = "success" ] || [ "$STATUS" = "failure" ] || [ "$STATUS" = "error" ]; then
                break
              fi
              sleep 30
            done
            ```

            ## 5. Auto-Fixing CI Failures

            When CI fails, diagnose and fix. This loop works with either auth method.

            ### Step 1: Get Failure Details

            **With gh:**

            ```bash
            # List recent workflow runs on this branch
            gh run list --branch $(git branch --show-current) --limit 5

            # View failed logs
            gh run view <RUN_ID> --log-failed
            ```

            **With git + curl:**

            ```bash
            BRANCH=$(git branch --show-current)

            # List workflow runs on this branch
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/repos/$OWNER/$REPO/actions/runs?branch=$BRANCH&per_page=5" \
              | python3 -c "
            import sys, json
            runs = json.load(sys.stdin)['workflow_runs']
            for r in runs:
                print(f\"Run {r['id']}: {r['name']} - {r['conclusion'] or r['status']}\")"

            # Get failed job logs (download as zip, extract, read)
            RUN_ID=<run_id>
            curl -s -L \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/runs/$RUN_ID/logs \
              -o /tmp/ci-logs.zip
            cd /tmp && unzip -o ci-logs.zip -d ci-logs && cat ci-logs/*.txt
            ```

            ### Step 2: Fix and Push

            After identifying the issue, use file tools (`patch`, `write_file`) to fix it:

            ```bash
            git add <fixed_files>
            git commit -m "fix: resolve CI failure in <check_name>"
            git push
            ```

            ### Step 3: Verify

            Re-check CI status using the commands from Section 4 above.

            ### Auto-Fix Loop Pattern

            When asked to auto-fix CI, follow this loop:

            1. Check CI status → identify failures
            2. Read failure logs → understand the error
            3. Use `read_file` + `patch`/`write_file` → fix the code
            4. `git add . && git commit -m "fix: ..." && git push`
            5. Wait for CI → re-check status
            6. Repeat if still failing (up to 3 attempts, then ask the user)

            ## 6. Merging

            **With gh:**

            ```bash
            # Squash merge + delete branch (cleanest for feature branches)
            gh pr merge --squash --delete-branch

            # Enable auto-merge (merges when all checks pass)
            gh pr merge --auto --squash --delete-branch
            ```

            **With git + curl:**

            ```bash
            PR_NUMBER=<number>

            # Merge the PR via API (squash)
            curl -s -X PUT \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/merge \
              -d "{
                \"merge_method\": \"squash\",
                \"commit_title\": \"feat: add user authentication (#$PR_NUMBER)\"
              }"

            # Delete the remote branch after merge
            BRANCH=$(git branch --show-current)
            git push origin --delete $BRANCH

            # Switch back to main locally
            git checkout main && git pull origin main
            git branch -d $BRANCH
            ```

            Merge methods: `"merge"` (merge commit), `"squash"`, `"rebase"`

            ### Enable Auto-Merge (curl)

            ```bash
            # Auto-merge requires the repo to have it enabled in settings.
            # This uses the GraphQL API since REST doesn't support auto-merge.
            PR_NODE_ID=$(curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['node_id'])")

            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/graphql \
              -d "{\"query\": \"mutation { enablePullRequestAutoMerge(input: {pullRequestId: \\\"$PR_NODE_ID\\\", mergeMethod: SQUASH}) { clientMutationId } }\"}"
            ```

            ## 7. Complete Workflow Example

            ```bash
            # 1. Start from clean main
            git checkout main && git pull origin main

            # 2. Branch
            git checkout -b fix/login-redirect-bug

            # 3. (Agent makes code changes with file tools)

            # 4. Commit
            git add src/auth/login.py tests/test_login.py
            git commit -m "fix: correct redirect URL after login

            Preserves the ?next= parameter instead of always redirecting to /dashboard."

            # 5. Push
            git push -u origin HEAD

            # 6. Create PR (picks gh or curl based on what's available)
            # ... (see Section 3)

            # 7. Monitor CI (see Section 4)

            # 8. Merge when green (see Section 6)
            ```

            ## Useful PR Commands Reference

            | Action | gh | git + curl |
            |--------|-----|-----------|
            | List my PRs | `gh pr list --author @me` | `curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$OWNER/$REPO/pulls?state=open"` |
            | View PR diff | `gh pr diff` | `git diff main...HEAD` (local) or `curl -H "Accept: application/vnd.github.diff" ...` |
            | Add comment | `gh pr comment N --body "..."` | `curl -X POST .../issues/N/comments -d '{"body":"..."}'` |
            | Request review | `gh pr edit N --add-reviewer user` | `curl -X POST .../pulls/N/requested_reviewers -d '{"reviewers":["user"]}'` |
            | Close PR | `gh pr close N` | `curl -X PATCH .../pulls/N -d '{"state":"closed"}'` |
            | Check out someone's PR | `gh pr checkout N` | `git fetch origin pull/N/head:pr-N && git checkout pr-N` |

            """#
        ),
        Entry(
            name: "github-repo-management",
            description: "Clone/create/fork repos; manage remotes, releases.",
            body: #"""
            ---
            name: github-repo-management
            description: "Clone/create/fork repos; manage remotes, releases."
            version: 1.1.0
            author: Hermes Agent
            license: MIT
            metadata:
              hermes:
                tags: [GitHub, Repositories, Git, Releases, Secrets, Configuration]
                related_skills: [github-auth, github-pr-workflow, github-issues]
            ---

            # GitHub Repository Management

            Create, clone, fork, configure, and manage GitHub repositories. Each section shows `gh` first, then the `git` + `curl` fallback.

            ## Prerequisites

            - Authenticated with GitHub (see `github-auth` skill)

            ### Setup

            ```bash
            if command -v gh &>/dev/null && gh auth status &>/dev/null; then
              AUTH="gh"
            else
              AUTH="git"
              if [ -z "$GITHUB_TOKEN" ]; then
                if [ -f ~/.hermes/.env ] && grep -q "^GITHUB_TOKEN=" ~/.hermes/.env; then
                  GITHUB_TOKEN=$(grep "^GITHUB_TOKEN=" ~/.hermes/.env | head -1 | cut -d= -f2 | tr -d '\n\r')
                elif grep -q "github.com" ~/.git-credentials 2>/dev/null; then
                  GITHUB_TOKEN=$(grep "github.com" ~/.git-credentials 2>/dev/null | head -1 | sed 's|https://[^:]*:\([^@]*\)@.*|\1|')
                fi
              fi
            fi

            # Get your GitHub username (needed for several operations)
            if [ "$AUTH" = "gh" ]; then
              GH_USER=$(gh api user --jq '.login')
            else
              GH_USER=$(curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user | python3 -c "import sys,json; print(json.load(sys.stdin)['login'])")
            fi
            ```

            If you're inside a repo already:

            ```bash
            REMOTE_URL=$(git remote get-url origin)
            OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
            OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
            REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
            ```

            ---

            ## 1. Cloning Repositories

            Cloning is pure `git` — works identically either way:

            ```bash
            # Clone via HTTPS (works with credential helper or token-embedded URL)
            git clone https://github.com/owner/repo-name.git

            # Clone into a specific directory
            git clone https://github.com/owner/repo-name.git ./my-local-dir

            # Shallow clone (faster for large repos)
            git clone --depth 1 https://github.com/owner/repo-name.git

            # Clone a specific branch
            git clone --branch develop https://github.com/owner/repo-name.git

            # Clone via SSH (if SSH is configured)
            git clone git@github.com:owner/repo-name.git
            ```

            **With gh (shorthand):**

            ```bash
            gh repo clone owner/repo-name
            gh repo clone owner/repo-name -- --depth 1
            ```

            ## 2. Creating Repositories

            **With gh:**

            ```bash
            # Create a public repo and clone it
            gh repo create my-new-project --public --clone

            # Private, with description and license
            gh repo create my-new-project --private --description "A useful tool" --license MIT --clone

            # Under an organization
            gh repo create my-org/my-new-project --public --clone

            # From existing local directory
            cd /path/to/existing/project
            gh repo create my-project --source . --public --push
            ```

            **With git + curl:**

            ```bash
            # Create the remote repo via API
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/user/repos \
              -d '{
                "name": "my-new-project",
                "description": "A useful tool",
                "private": false,
                "auto_init": true,
                "license_template": "mit"
              }'

            # Clone it
            git clone https://github.com/$GH_USER/my-new-project.git
            cd my-new-project

            # -- OR -- push an existing local directory to the new repo
            cd /path/to/existing/project
            git init
            git add .
            git commit -m "Initial commit"
            git remote add origin https://github.com/$GH_USER/my-new-project.git
            git push -u origin main
            ```

            To create under an organization:

            ```bash
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/orgs/my-org/repos \
              -d '{"name": "my-new-project", "private": false}'
            ```

            ### From a Template

            **With gh:**

            ```bash
            gh repo create my-new-app --template owner/template-repo --public --clone
            ```

            **With curl:**

            ```bash
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/owner/template-repo/generate \
              -d '{"owner": "'"$GH_USER"'", "name": "my-new-app", "private": false}'
            ```

            ## 3. Forking Repositories

            **With gh:**

            ```bash
            gh repo fork owner/repo-name --clone
            ```

            **With git + curl:**

            ```bash
            # Create the fork via API
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/owner/repo-name/forks

            # Wait a moment for GitHub to create it, then clone
            sleep 3
            git clone https://github.com/$GH_USER/repo-name.git
            cd repo-name

            # Add the original repo as "upstream" remote
            git remote add upstream https://github.com/owner/repo-name.git
            ```

            ### Keeping a Fork in Sync

            ```bash
            # Pure git — works everywhere
            git fetch upstream
            git checkout main
            git merge upstream/main
            git push origin main
            ```

            **With gh (shortcut):**

            ```bash
            gh repo sync $GH_USER/repo-name
            ```

            ## 4. Repository Information

            **With gh:**

            ```bash
            gh repo view owner/repo-name
            gh repo list --limit 20
            gh search repos "machine learning" --language python --sort stars
            ```

            **With curl:**

            ```bash
            # View repo details
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO \
              | python3 -c "
            import sys, json
            r = json.load(sys.stdin)
            print(f\"Name: {r['full_name']}\")
            print(f\"Description: {r['description']}\")
            print(f\"Stars: {r['stargazers_count']}  Forks: {r['forks_count']}\")
            print(f\"Default branch: {r['default_branch']}\")
            print(f\"Language: {r['language']}\")"

            # List your repos
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/user/repos?per_page=20&sort=updated" \
              | python3 -c "
            import sys, json
            for r in json.load(sys.stdin):
                vis = 'private' if r['private'] else 'public'
                print(f\"  {r['full_name']:40}  {vis:8}  {r.get('language', ''):10}  ★{r['stargazers_count']}\")"

            # Search repos
            curl -s \
              "https://api.github.com/search/repositories?q=machine+learning+language:python&sort=stars&per_page=10" \
              | python3 -c "
            import sys, json
            for r in json.load(sys.stdin)['items']:
                print(f\"  {r['full_name']:40}  ★{r['stargazers_count']:6}  {r['description'][:60] if r['description'] else ''}\")"
            ```

            ## 5. Repository Settings

            **With gh:**

            ```bash
            gh repo edit --description "Updated description" --visibility public
            gh repo edit --enable-wiki=false --enable-issues=true
            gh repo edit --default-branch main
            gh repo edit --add-topic "machine-learning,python"
            gh repo edit --enable-auto-merge
            ```

            **With curl:**

            ```bash
            curl -s -X PATCH \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO \
              -d '{
                "description": "Updated description",
                "has_wiki": false,
                "has_issues": true,
                "allow_auto_merge": true
              }'

            # Update topics
            curl -s -X PUT \
              -H "Authorization: token $GITHUB_TOKEN" \
              -H "Accept: application/vnd.github.mercy-preview+json" \
              https://api.github.com/repos/$OWNER/$REPO/topics \
              -d '{"names": ["machine-learning", "python", "automation"]}'
            ```

            ## 6. Branch Protection

            ```bash
            # View current protection
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/branches/main/protection

            # Set up branch protection
            curl -s -X PUT \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/branches/main/protection \
              -d '{
                "required_status_checks": {
                  "strict": true,
                  "contexts": ["ci/test", "ci/lint"]
                },
                "enforce_admins": false,
                "required_pull_request_reviews": {
                  "required_approving_review_count": 1
                },
                "restrictions": null
              }'
            ```

            ## 7. Secrets Management (GitHub Actions)

            **With gh:**

            ```bash
            gh secret set API_KEY --body "your-secret-value"
            gh secret set SSH_KEY < ~/.ssh/id_rsa
            gh secret list
            gh secret delete API_KEY
            ```

            **With curl:**

            Secrets require encryption with the repo's public key — more involved via API:

            ```bash
            # Get the repo's public key for encrypting secrets
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/secrets/public-key

            # Encrypt and set (requires Python with PyNaCl)
            python3 -c "
            from base64 import b64encode
            from nacl import encoding, public
            import json, sys

            # Get the public key
            key_id = '<key_id_from_above>'
            public_key = '<base64_key_from_above>'

            # Encrypt
            sealed = public.SealedBox(
                public.PublicKey(public_key.encode('utf-8'), encoding.Base64Encoder)
            ).encrypt('your-secret-value'.encode('utf-8'))
            print(json.dumps({
                'encrypted_value': b64encode(sealed).decode('utf-8'),
                'key_id': key_id
            }))"

            # Then PUT the encrypted secret
            curl -s -X PUT \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/secrets/API_KEY \
              -d '<output from python script above>'

            # List secrets (names only, values hidden)
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/secrets \
              | python3 -c "
            import sys, json
            for s in json.load(sys.stdin)['secrets']:
                print(f\"  {s['name']:30}  updated: {s['updated_at']}\")"
            ```

            Note: For secrets, `gh secret set` is dramatically simpler. If setting secrets is needed and `gh` isn't available, recommend installing it for just that operation.

            ## 8. Releases

            **With gh:**

            ```bash
            gh release create v1.0.0 --title "v1.0.0" --generate-notes
            gh release create v2.0.0-rc1 --draft --prerelease --generate-notes
            gh release create v1.0.0 ./dist/binary --title "v1.0.0" --notes "Release notes"
            gh release list
            gh release download v1.0.0 --dir ./downloads
            ```

            **With curl:**

            ```bash
            # Create a release
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/releases \
              -d '{
                "tag_name": "v1.0.0",
                "name": "v1.0.0",
                "body": "## Changelog\n- Feature A\n- Bug fix B",
                "draft": false,
                "prerelease": false,
                "generate_release_notes": true
              }'

            # List releases
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/releases \
              | python3 -c "
            import sys, json
            for r in json.load(sys.stdin):
                tag = r.get('tag_name', 'no tag')
                print(f\"  {tag:15}  {r['name']:30}  {'draft' if r['draft'] else 'published'}\")"

            # Upload a release asset (binary file)
            RELEASE_ID=<id_from_create_response>
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              -H "Content-Type: application/octet-stream" \
              "https://uploads.github.com/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=binary-amd64" \
              --data-binary @./dist/binary-amd64
            ```

            ## 9. GitHub Actions Workflows

            **With gh:**

            ```bash
            gh workflow list
            gh run list --limit 10
            gh run view <RUN_ID>
            gh run view <RUN_ID> --log-failed
            gh run rerun <RUN_ID>
            gh run rerun <RUN_ID> --failed
            gh workflow run ci.yml --ref main
            gh workflow run deploy.yml -f environment=staging
            ```

            **With curl:**

            ```bash
            # List workflows
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/workflows \
              | python3 -c "
            import sys, json
            for w in json.load(sys.stdin)['workflows']:
                print(f\"  {w['id']:10}  {w['name']:30}  {w['state']}\")"

            # List recent runs
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              "https://api.github.com/repos/$OWNER/$REPO/actions/runs?per_page=10" \
              | python3 -c "
            import sys, json
            for r in json.load(sys.stdin)['workflow_runs']:
                print(f\"  Run {r['id']}  {r['name']:30}  {r['conclusion'] or r['status']}\")"

            # Download failed run logs
            RUN_ID=<run_id>
            curl -s -L \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/runs/$RUN_ID/logs \
              -o /tmp/ci-logs.zip
            cd /tmp && unzip -o ci-logs.zip -d ci-logs

            # Re-run a failed workflow
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/runs/$RUN_ID/rerun

            # Re-run only failed jobs
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/runs/$RUN_ID/rerun-failed-jobs

            # Trigger a workflow manually (workflow_dispatch)
            WORKFLOW_ID=<workflow_id_or_filename>
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/repos/$OWNER/$REPO/actions/workflows/$WORKFLOW_ID/dispatches \
              -d '{"ref": "main", "inputs": {"environment": "staging"}}'
            ```

            ## 10. Gists

            **With gh:**

            ```bash
            gh gist create script.py --public --desc "Useful script"
            gh gist list
            ```

            **With curl:**

            ```bash
            # Create a gist
            curl -s -X POST \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/gists \
              -d '{
                "description": "Useful script",
                "public": true,
                "files": {
                  "script.py": {"content": "print(\"hello\")"}
                }
              }'

            # List your gists
            curl -s \
              -H "Authorization: token $GITHUB_TOKEN" \
              https://api.github.com/gists \
              | python3 -c "
            import sys, json
            for g in json.load(sys.stdin):
                files = ', '.join(g['files'].keys())
                print(f\"  {g['id']}  {g['description'] or '(no desc)':40}  {files}\")"
            ```

            ## Quick Reference Table

            | Action | gh | git + curl |
            |--------|-----|-----------|
            | Clone | `gh repo clone o/r` | `git clone https://github.com/o/r.git` |
            | Create repo | `gh repo create name --public` | `curl POST /user/repos` |
            | Fork | `gh repo fork o/r --clone` | `curl POST /repos/o/r/forks` + `git clone` |
            | Repo info | `gh repo view o/r` | `curl GET /repos/o/r` |
            | Edit settings | `gh repo edit --...` | `curl PATCH /repos/o/r` |
            | Create release | `gh release create v1.0` | `curl POST /repos/o/r/releases` |
            | List workflows | `gh workflow list` | `curl GET /repos/o/r/actions/workflows` |
            | Rerun CI | `gh run rerun ID` | `curl POST /repos/o/r/actions/runs/ID/rerun` |
            | Set secret | `gh secret set KEY` | `curl PUT /repos/o/r/actions/secrets/KEY` (+ encryption) |

            """#
        ),
        Entry(
            name: "google-workspace",
            description: "Gmail, Calendar, Drive, Docs, Sheets via gws CLI or Python.",
            body: #"""
            ---
            name: google-workspace
            description: "Gmail, Calendar, Drive, Docs, Sheets via gws CLI or Python."
            version: 1.0.1
            author: Nous Research
            license: MIT
            required_credential_files:
              - path: google_token.json
                description: Google OAuth2 token (created by setup script)
              - path: google_client_secret.json
                description: Google OAuth2 client credentials (downloaded from Google Cloud Console)
            metadata:
              hermes:
                tags: [Google, Gmail, Calendar, Drive, Sheets, Docs, Contacts, Email, OAuth]
                homepage: https://github.com/NousResearch/hermes-agent
                related_skills: [himalaya]
            ---

            # Google Workspace

            Gmail, Calendar, Drive, Contacts, Sheets, and Docs — through Hermes-managed OAuth and a thin CLI wrapper. When `gws` is installed, the skill uses it as the execution backend for broader Google Workspace coverage; otherwise it falls back to the bundled Python client implementation.

            ## References

            - `references/gmail-search-syntax.md` — Gmail search operators (is:unread, from:, newer_than:, etc.)

            ## Scripts

            - `scripts/setup.py` — OAuth2 setup (run once to authorize)
            - `scripts/google_api.py` — compatibility wrapper CLI. It prefers `gws` for operations when available, while preserving Hermes' existing JSON output contract.

            ## First-Time Setup

            The setup is fully non-interactive — you drive it step by step so it works
            on CLI, Telegram, Discord, or any platform.

            Define a shorthand first:

            ```bash
            GSETUP="python ${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/setup.py"
            ```

            ### Step 0: Check if already set up

            ```bash
            $GSETUP --check
            ```

            If it prints `AUTHENTICATED`, skip to Usage — setup is already done.

            ### Step 1: Triage — ask the user what they need

            Before starting OAuth setup, ask the user TWO questions:

            **Question 1: "What Google services do you need? Just email, or also
            Calendar/Drive/Sheets/Docs?"**

            - **Email only** → They don't need this skill at all. Use the `himalaya` skill
              instead — it works with a Gmail App Password (Settings → Security → App
              Passwords) and takes 2 minutes to set up. No Google Cloud project needed.
              Load the himalaya skill and follow its setup instructions.

            - **Email + Calendar** → Continue with this skill, but use
              `--services email,calendar` during auth so the consent screen only asks for
              the scopes they actually need.

            - **Calendar/Drive/Sheets/Docs only** → Continue with this skill and use a
              narrower `--services` set like `calendar,drive,sheets,docs`.

            - **Full Workspace access** → Continue with this skill and use the default
              `all` service set.

            **Question 2: "Does your Google account use Advanced Protection (hardware
            security keys required to sign in)? If you're not sure, you probably don't
            — it's something you would have explicitly enrolled in."**

            - **No / Not sure** → Normal setup. Continue below.
            - **Yes** → Their Workspace admin must add the OAuth client ID to the org's
              allowed apps list before Step 4 will work. Let them know upfront.

            ### Step 2: Create OAuth credentials (one-time, ~5 minutes)

            Tell the user:

            > You need a Google Cloud OAuth client. This is a one-time setup:
            >
            > 1. Create or select a project:
            >    https://console.cloud.google.com/projectselector2/home/dashboard
            > 2. Enable the required APIs from the API Library:
            >    https://console.cloud.google.com/apis/library
            >    Enable: Gmail API, Google Calendar API, Google Drive API,
            >    Google Sheets API, Google Docs API, People API
            > 3. Create the OAuth client here:
            >    https://console.cloud.google.com/apis/credentials
            >    Credentials → Create Credentials → OAuth 2.0 Client ID
            > 4. Application type: "Desktop app" → Create
            > 5. If the app is still in Testing, add the user's Google account as a test user here:
            >    https://console.cloud.google.com/auth/audience
            >    Audience → Test users → Add users
            > 6. Download the JSON file and tell me the file path
            >
            > Important Hermes CLI note: if the file path starts with `/`, do NOT send only the bare path as its own message in the CLI, because it can be mistaken for a slash command. Send it in a sentence instead, like:
            > `The JSON file path is: /home/user/Downloads/client_secret_....json`

            Once they provide the path:

            ```bash
            $GSETUP --client-secret /path/to/client_secret.json
            ```

            If they paste the raw client ID / client secret values instead of a file path,
            write a valid Desktop OAuth JSON file for them yourself, save it somewhere
            explicit (for example `~/Downloads/hermes-google-client-secret.json`), then run
            `--client-secret` against that file.

            ### Step 3: Get authorization URL

            Use the service set chosen in Step 1. Examples:

            ```bash
            $GSETUP --auth-url --services email,calendar --format json
            $GSETUP --auth-url --services calendar,drive,sheets,docs --format json
            $GSETUP --auth-url --services all --format json
            ```

            This returns JSON with an `auth_url` field and also saves the exact URL to
            `~/.hermes/google_oauth_last_url.txt`.

            Agent rules for this step:
            - Extract the `auth_url` field and send that exact URL to the user as a single line.
            - Tell the user that the browser will likely fail on `http://localhost:1` after approval, and that this is expected.
            - Tell them to copy the ENTIRE redirected URL from the browser address bar.
            - If the user gets `Error 403: access_denied`, send them directly to `https://console.cloud.google.com/auth/audience` to add themselves as a test user.

            ### Step 4: Exchange the code

            The user will paste back either a URL like `http://localhost:1/?code=4/0A...&scope=...`
            or just the code string. Either works. The `--auth-url` step stores a temporary
            pending OAuth session locally so `--auth-code` can complete the PKCE exchange
            later, even on headless systems:

            ```bash
            $GSETUP --auth-code "THE_URL_OR_CODE_THE_USER_PASTED" --format json
            ```

            If `--auth-code` fails because the code expired, was already used, or came from
            an older browser tab, it now returns a fresh `fresh_auth_url`. In that case,
            immediately send the new URL to the user and have them retry with the newest
            browser redirect only.

            ### Step 5: Verify

            ```bash
            $GSETUP --check
            ```

            Should print `AUTHENTICATED`. Setup is complete — token refreshes automatically from now on.

            ### Notes

            - Token is stored at `~/.hermes/google_token.json` and auto-refreshes.
            - Pending OAuth session state/verifier are stored temporarily at `~/.hermes/google_oauth_pending.json` until exchange completes.
            - If `gws` is installed, `google_api.py` points it at the same `~/.hermes/google_token.json` credentials file. Users do not need to run a separate `gws auth login` flow.
            - To revoke: `$GSETUP --revoke`

            ## Usage

            All commands go through the API script. Set `GAPI` as a shorthand:

            ```bash
            GAPI="python ${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py"
            ```

            ### Gmail

            ```bash
            # Search (returns JSON array with id, from, subject, date, snippet)
            $GAPI gmail search "is:unread" --max 10
            $GAPI gmail search "from:boss@company.com newer_than:1d"
            $GAPI gmail search "has:attachment filename:pdf newer_than:7d"

            # Read full message (returns JSON with body text)
            $GAPI gmail get MESSAGE_ID

            # Send
            $GAPI gmail send --to user@example.com --subject "Hello" --body "Message text"
            $GAPI gmail send --to user@example.com --subject "Report" --body "<h1>Q4</h1><p>Details...</p>" --html
            $GAPI gmail send --to user@example.com --subject "Hello" --from '"Research Agent" <user@example.com>' --body "Message text"

            # Reply (automatically threads and sets In-Reply-To)
            $GAPI gmail reply MESSAGE_ID --body "Thanks, that works for me."
            $GAPI gmail reply MESSAGE_ID --from '"Support Bot" <user@example.com>' --body "Thanks"

            # Labels
            $GAPI gmail labels
            $GAPI gmail modify MESSAGE_ID --add-labels LABEL_ID
            $GAPI gmail modify MESSAGE_ID --remove-labels UNREAD
            ```

            ### Calendar

            ```bash
            # List events (defaults to next 7 days)
            $GAPI calendar list
            $GAPI calendar list --start 2026-03-01T00:00:00Z --end 2026-03-07T23:59:59Z

            # Create event (ISO 8601 with timezone required)
            $GAPI calendar create --summary "Team Standup" --start 2026-03-01T10:00:00-06:00 --end 2026-03-01T10:30:00-06:00
            $GAPI calendar create --summary "Lunch" --start 2026-03-01T12:00:00Z --end 2026-03-01T13:00:00Z --location "Cafe"
            $GAPI calendar create --summary "Review" --start 2026-03-01T14:00:00Z --end 2026-03-01T15:00:00Z --attendees "alice@co.com,bob@co.com"

            # Delete event
            $GAPI calendar delete EVENT_ID
            ```

            ### Drive

            ```bash
            $GAPI drive search "quarterly report" --max 10
            $GAPI drive search "mimeType='application/pdf'" --raw-query --max 5
            ```

            ### Contacts

            ```bash
            $GAPI contacts list --max 20
            ```

            ### Sheets

            ```bash
            # Read
            $GAPI sheets get SHEET_ID "Sheet1!A1:D10"

            # Write
            $GAPI sheets update SHEET_ID "Sheet1!A1:B2" --values '[["Name","Score"],["Alice","95"]]'

            # Append rows
            $GAPI sheets append SHEET_ID "Sheet1!A:C" --values '[["new","row","data"]]'
            ```

            ### Docs

            ```bash
            $GAPI docs get DOC_ID
            ```

            ## Output Format

            All commands return JSON. Parse with `jq` or read directly. Key fields:

            - **Gmail search**: `[{id, threadId, from, to, subject, date, snippet, labels}]`
            - **Gmail get**: `{id, threadId, from, to, subject, date, labels, body}`
            - **Gmail send/reply**: `{status: "sent", id, threadId}`
            - **Calendar list**: `[{id, summary, start, end, location, description, htmlLink}]`
            - **Calendar create**: `{status: "created", id, summary, htmlLink}`
            - **Drive search**: `[{id, name, mimeType, modifiedTime, webViewLink}]`
            - **Contacts list**: `[{name, emails: [...], phones: [...]}]`
            - **Sheets get**: `[[cell, cell, ...], ...]`

            ## Rules

            1. **Never send email or create/delete events without confirming with the user first.** Show the draft content and ask for approval.
            2. **Check auth before first use** — run `setup.py --check`. If it fails, guide the user through setup.
            3. **Use the Gmail search syntax reference** for complex queries — load it with `skill_view("google-workspace", file_path="references/gmail-search-syntax.md")`.
            4. **Calendar times must include timezone** — always use ISO 8601 with offset (e.g., `2026-03-01T10:00:00-06:00`) or UTC (`Z`).
            5. **Respect rate limits** — avoid rapid-fire sequential API calls. Batch reads when possible.

            ## Troubleshooting

            | Problem | Fix |
            |---------|-----|
            | `NOT_AUTHENTICATED` | Run setup Steps 2-5 above |
            | `REFRESH_FAILED` | Token revoked or expired — redo Steps 3-5 |
            | `HttpError 403: Insufficient Permission` | Missing API scope — `$GSETUP --revoke` then redo Steps 3-5 |
            | `HttpError 403: Access Not Configured` | API not enabled — user needs to enable it in Google Cloud Console |
            | `ModuleNotFoundError` | Run `$GSETUP --install-deps` |
            | Advanced Protection blocks auth | Workspace admin must allowlist the OAuth client ID |

            ## Revoking Access

            ```bash
            $GSETUP --revoke
            ```

            """#
        ),
        Entry(
            name: "imessage",
            description: "Send and receive iMessages/SMS via the imsg CLI on macOS.",
            body: #"""
            ---
            name: imessage
            description: Send and receive iMessages/SMS via the imsg CLI on macOS.
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            platforms: [macos]
            metadata:
              hermes:
                tags: [iMessage, SMS, messaging, macOS, Apple]
            prerequisites:
              commands: [imsg]
            ---

            # iMessage

            Use `imsg` to read and send iMessage/SMS via macOS Messages.app.

            ## Prerequisites

            - **macOS** with Messages.app signed in
            - Install: `brew install steipete/tap/imsg`
            - Grant Full Disk Access for terminal (System Settings → Privacy → Full Disk Access)
            - Grant Automation permission for Messages.app when prompted

            ## When to Use

            - User asks to send an iMessage or text message
            - Reading iMessage conversation history
            - Checking recent Messages.app chats
            - Sending to phone numbers or Apple IDs

            ## When NOT to Use

            - Telegram/Discord/Slack/WhatsApp messages → use the appropriate gateway channel
            - Group chat management (adding/removing members) → not supported
            - Bulk/mass messaging → always confirm with user first

            ## Quick Reference

            ### List Chats

            ```bash
            imsg chats --limit 10 --json
            ```

            ### View History

            ```bash
            # By chat ID
            imsg history --chat-id 1 --limit 20 --json

            # With attachments info
            imsg history --chat-id 1 --limit 20 --attachments --json
            ```

            ### Send Messages

            ```bash
            # Text only
            imsg send --to "+14155551212" --text "Hello!"

            # With attachment
            imsg send --to "+14155551212" --text "Check this out" --file /path/to/image.jpg

            # Force iMessage or SMS
            imsg send --to "+14155551212" --text "Hi" --service imessage
            imsg send --to "+14155551212" --text "Hi" --service sms
            ```

            ### Watch for New Messages

            ```bash
            imsg watch --chat-id 1 --attachments
            ```

            ## Service Options

            - `--service imessage` — Force iMessage (requires recipient has iMessage)
            - `--service sms` — Force SMS (green bubble)
            - `--service auto` — Let Messages.app decide (default)

            ## Rules

            1. **Always confirm recipient and message content** before sending
            2. **Never send to unknown numbers** without explicit user approval
            3. **Verify file paths** exist before attaching
            4. **Don't spam** — rate-limit yourself

            ## Example Workflow

            User: "Text mom that I'll be late"

            ```bash
            # 1. Find mom's chat
            imsg chats --limit 20 --json | jq '.[] | select(.displayName | contains("Mom"))'

            # 2. Confirm with user: "Found Mom at +1555123456. Send 'I'll be late' via iMessage?"

            # 3. Send after confirmation
            imsg send --to "+1555123456" --text "I'll be late"
            ```

            """#
        ),
        Entry(
            name: "linear",
            description: "Linear: manage issues, projects, teams via GraphQL + curl.",
            body: #"""
            ---
            name: linear
            description: "Linear: manage issues, projects, teams via GraphQL + curl."
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            prerequisites:
              env_vars: [LINEAR_API_KEY]
              commands: [curl]
            metadata:
              hermes:
                tags: [Linear, Project Management, Issues, GraphQL, API, Productivity]
            ---

            # Linear — Issue & Project Management

            Manage Linear issues, projects, and teams directly via the GraphQL API using `curl`. No MCP server, no OAuth flow, no extra dependencies.

            ## Setup

            1. Get a personal API key from **Linear Settings > Account > Security & access > Personal API keys** (URL: https://linear.app/settings/account/security). Note: the org-level *Settings > API* page only shows OAuth apps and workspace-member keys, not personal keys.
            2. Set `LINEAR_API_KEY` in your environment (via `hermes setup` or your env config)

            ## API Basics

            - **Endpoint:** `https://api.linear.app/graphql` (POST)
            - **Auth header:** `Authorization: $LINEAR_API_KEY` (no "Bearer" prefix for API keys)
            - **All requests are POST** with `Content-Type: application/json`
            - **Both UUIDs and short identifiers** (e.g., `ENG-123`) work for `issue(id:)`

            Base curl pattern:
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ viewer { id name } }"}' | python3 -m json.tool
            ```

            ## Python helper script (ergonomic alternative)

            For faster one-liners that don't need hand-written GraphQL, this skill ships a stdlib Python CLI at `scripts/linear_api.py`. Zero dependencies. Same auth (reads `LINEAR_API_KEY`).

            ```bash
            SCRIPT=$(dirname "$(find ~/.hermes -path '*skills/productivity/linear/scripts/linear_api.py' 2>/dev/null | head -1)")/linear_api.py

            python3 "$SCRIPT" whoami
            python3 "$SCRIPT" list-teams
            python3 "$SCRIPT" get-issue ENG-42
            python3 "$SCRIPT" get-document 38359beef67c      # fetch a doc by slugId from the URL
            python3 "$SCRIPT" raw 'query { viewer { name } }'
            ```

            All subcommands: `whoami`, `list-teams`, `list-projects`, `list-states`, `list-issues`, `get-issue`, `search-issues`, `create-issue`, `update-issue`, `update-status`, `add-comment`, `list-documents`, `get-document`, `search-documents`, `raw`. Run with `--help` for flags.

            Use the script when: you want a quick answer without crafting GraphQL. Use curl when: you need a query the script doesn't wrap, or you want to compose filters inline.

            ## Workflow States

            Linear uses `WorkflowState` objects with a `type` field. **6 state types:**

            | Type | Description |
            |------|-------------|
            | `triage` | Incoming issues needing review |
            | `backlog` | Acknowledged but not yet planned |
            | `unstarted` | Planned/ready but not started |
            | `started` | Actively being worked on |
            | `completed` | Done |
            | `canceled` | Won't do |

            Each team has its own named states (e.g., "In Progress" is type `started`). To change an issue's status, you need the `stateId` (UUID) of the target state — query workflow states first.

            **Priority values:** 0 = None, 1 = Urgent, 2 = High, 3 = Medium, 4 = Low

            ## Common Queries

            ### Get current user
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ viewer { id name email } }"}' | python3 -m json.tool
            ```

            ### List teams
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ teams { nodes { id name key } } }"}' | python3 -m json.tool
            ```

            ### List workflow states for a team
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ workflowStates(filter: { team: { key: { eq: \"ENG\" } } }) { nodes { id name type } } }"}' | python3 -m json.tool
            ```

            ### List issues (first 20)
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issues(first: 20) { nodes { identifier title priority state { name type } assignee { name } team { key } url } pageInfo { hasNextPage endCursor } } }"}' | python3 -m json.tool
            ```

            ### List my assigned issues
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ viewer { assignedIssues(first: 25) { nodes { identifier title state { name type } priority url } } } }"}' | python3 -m json.tool
            ```

            ### Get a single issue (by identifier like ENG-123)
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issue(id: \"ENG-123\") { id identifier title description priority state { id name type } assignee { id name } team { key } project { name } labels { nodes { name } } comments { nodes { body user { name } createdAt } } url } }"}' | python3 -m json.tool
            ```

            ### Search issues by text
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issueSearch(query: \"bug login\", first: 10) { nodes { identifier title state { name } assignee { name } url } } }"}' | python3 -m json.tool
            ```

            ### Filter issues by state type
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issues(filter: { state: { type: { in: [\"started\"] } } }, first: 20) { nodes { identifier title state { name } assignee { name } } } }"}' | python3 -m json.tool
            ```

            ### Filter by team and assignee
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issues(filter: { team: { key: { eq: \"ENG\" } }, assignee: { email: { eq: \"user@example.com\" } } }, first: 20) { nodes { identifier title state { name } priority } } }"}' | python3 -m json.tool
            ```

            ### List projects
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ projects(first: 20) { nodes { id name description progress lead { name } teams { nodes { key } } url } } }"}' | python3 -m json.tool
            ```

            ### List team members
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ users { nodes { id name email active } } }"}' | python3 -m json.tool
            ```

            ### List labels
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issueLabels { nodes { id name color } } }"}' | python3 -m json.tool
            ```

            ## Common Mutations

            ### Create an issue
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{
                "query": "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier title url } } }",
                "variables": {
                  "input": {
                    "teamId": "TEAM_UUID",
                    "title": "Fix login bug",
                    "description": "Users cannot login with SSO",
                    "priority": 2
                  }
                }
              }' | python3 -m json.tool
            ```

            ### Update issue status
            First get the target state UUID from the workflow states query above, then:
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "mutation { issueUpdate(id: \"ENG-123\", input: { stateId: \"STATE_UUID\" }) { success issue { identifier state { name type } } } }"}' | python3 -m json.tool
            ```

            ### Assign an issue
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "mutation { issueUpdate(id: \"ENG-123\", input: { assigneeId: \"USER_UUID\" }) { success issue { identifier assignee { name } } } }"}' | python3 -m json.tool
            ```

            ### Set priority
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "mutation { issueUpdate(id: \"ENG-123\", input: { priority: 1 }) { success issue { identifier priority } } }"}' | python3 -m json.tool
            ```

            ### Add a comment
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "mutation { commentCreate(input: { issueId: \"ISSUE_UUID\", body: \"Investigated. Root cause is X.\" }) { success comment { id body } } }"}' | python3 -m json.tool
            ```

            ### Set due date
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "mutation { issueUpdate(id: \"ENG-123\", input: { dueDate: \"2026-04-01\" }) { success issue { identifier dueDate } } }"}' | python3 -m json.tool
            ```

            ### Add labels to an issue
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "mutation { issueUpdate(id: \"ENG-123\", input: { labelIds: [\"LABEL_UUID_1\", \"LABEL_UUID_2\"] }) { success issue { identifier labels { nodes { name } } } } }"}' | python3 -m json.tool
            ```

            ### Add issue to a project
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "mutation { issueUpdate(id: \"ENG-123\", input: { projectId: \"PROJECT_UUID\" }) { success issue { identifier project { name } } } }"}' | python3 -m json.tool
            ```

            ### Create a project
            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{
                "query": "mutation($input: ProjectCreateInput!) { projectCreate(input: $input) { success project { id name url } } }",
                "variables": {
                  "input": {
                    "name": "Q2 Auth Overhaul",
                    "description": "Replace legacy auth with OAuth2 and PKCE",
                    "teamIds": ["TEAM_UUID"]
                  }
                }
              }' | python3 -m json.tool
            ```

            ## Documents

            Linear **Documents** are prose docs (RFCs, specs, notes) stored alongside issues. They have their own `documents` root query and `document(id:)` single-fetch.

            ### Document URLs and `slugId`

            Document URLs look like:
            ```
            https://linear.app/<workspace>/document/<slug>-<hexSlugId>
            ```

            The trailing hex segment is the `slugId`. Example: `https://linear.app/nousresearch/document/rfc-hermes-permission-gateway-discord-38359beef67c` → `slugId` is `38359beef67c`.

            **Important schema detail:** the Markdown body is in the `content` field. The ProseMirror JSON is in `contentState` (not `contentData` — that field does not exist and the API returns 400).

            ### Fetch a document by slugId

            `document(id:)` only accepts UUIDs. To fetch by the URL's hex slug, filter the collection:

            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "query($s: String!) { documents(filter: { slugId: { eq: $s } }, first: 1) { nodes { id title content contentState slugId url creator { name } project { name } updatedAt } } }", "variables": {"s": "38359beef67c"}}' \
              | python3 -m json.tool
            ```

            Or via the Python helper:
            ```bash
            python3 scripts/linear_api.py get-document 38359beef67c
            ```

            ### Fetch a document by UUID

            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ document(id: \"11700cff-b514-4db3-afcc-3ed1afacba1c\") { title content url } }"}' \
              | python3 -m json.tool
            ```

            ### List recent documents

            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ documents(first: 25, orderBy: updatedAt) { nodes { id title slugId url updatedAt project { name } } } }"}' \
              | python3 -m json.tool
            ```

            ### Search documents by title

            Linear's schema has no `searchDocuments` root. Use a title-substring filter instead:

            ```bash
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ documents(filter: { title: { containsIgnoreCase: \"RFC\" } }, first: 25) { nodes { title slugId url } } }"}' \
              | python3 -m json.tool
            ```

            ## Pagination

            Linear uses Relay-style cursor pagination:

            ```bash
            # First page
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issues(first: 20) { nodes { identifier title } pageInfo { hasNextPage endCursor } } }"}' | python3 -m json.tool

            # Next page — use endCursor from previous response
            curl -s -X POST https://api.linear.app/graphql \
              -H "Authorization: $LINEAR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ issues(first: 20, after: \"CURSOR_FROM_PREVIOUS\") { nodes { identifier title } pageInfo { hasNextPage endCursor } } }"}' | python3 -m json.tool
            ```

            Default page size: 50. Max: 250. Always use `first: N` to limit results.

            ## Filtering Reference

            Comparators: `eq`, `neq`, `in`, `nin`, `lt`, `lte`, `gt`, `gte`, `contains`, `startsWith`, `containsIgnoreCase`

            Combine filters with `or: [...]` for OR logic (default is AND within a filter object).

            ## Typical Workflow

            1. **Query teams** to get team IDs and keys
            2. **Query workflow states** for target team to get state UUIDs
            3. **List or search issues** to find what needs work
            4. **Create issues** with team ID, title, description, priority
            5. **Update status** by setting `stateId` to the target workflow state
            6. **Add comments** to track progress
            7. **Mark complete** by setting `stateId` to the team's "completed" type state

            ## Rate Limits

            - 5,000 requests/hour per API key
            - 3,000,000 complexity points/hour
            - Use `first: N` to limit results and reduce complexity cost
            - Monitor `X-RateLimit-Requests-Remaining` response header

            ## Important Notes

            - Always use `terminal` tool with `curl` for API calls — do NOT use `web_extract` or `browser`
            - Always check the `errors` array in GraphQL responses — HTTP 200 can still contain errors
            - If `stateId` is omitted when creating issues, Linear defaults to the first backlog state
            - The `description` field supports Markdown
            - Use `python3 -m json.tool` or `jq` to format JSON responses for readability

            """#
        ),
        Entry(
            name: "maps",
            description: "Geocode, POIs, routes, timezones via OpenStreetMap/OSRM.",
            body: #"""
            ---
            name: maps
            description: "Geocode, POIs, routes, timezones via OpenStreetMap/OSRM."
            version: 1.2.0
            author: Mibayy
            license: MIT
            metadata:
              hermes:
                tags: [maps, geocoding, places, routing, distance, directions, nearby, location, openstreetmap, nominatim, overpass, osrm]
                category: productivity
                requires_toolsets: [terminal]
                supersedes: [find-nearby]
            ---

            # Maps Skill

            Location intelligence using free, open data sources. 8 commands, 44 POI
            categories, zero dependencies (Python stdlib only), no API key required.

            Data sources: OpenStreetMap/Nominatim, Overpass API, OSRM, TimeAPI.io.

            This skill supersedes the old `find-nearby` skill — all of find-nearby's
            functionality is covered by the `nearby` command below, with the same
            `--near "<place>"` shortcut and multi-category support.

            ## When to Use

            - User sends a Telegram location pin (latitude/longitude in the message) → `nearby`
            - User wants coordinates for a place name → `search`
            - User has coordinates and wants the address → `reverse`
            - User asks for nearby restaurants, hospitals, pharmacies, hotels, etc. → `nearby`
            - User wants driving/walking/cycling distance or travel time → `distance`
            - User wants turn-by-turn directions between two places → `directions`
            - User wants timezone information for a location → `timezone`
            - User wants to search for POIs within a geographic area → `area` + `bbox`

            ## Prerequisites

            Python 3.8+ (stdlib only — no pip installs needed).

            Script path: `~/.hermes/skills/maps/scripts/maps_client.py`

            ## Commands

            ```bash
            MAPS=~/.hermes/skills/maps/scripts/maps_client.py
            ```

            ### search — Geocode a place name

            ```bash
            python3 $MAPS search "Eiffel Tower"
            python3 $MAPS search "1600 Pennsylvania Ave, Washington DC"
            ```

            Returns: lat, lon, display name, type, bounding box, importance score.

            ### reverse — Coordinates to address

            ```bash
            python3 $MAPS reverse 48.8584 2.2945
            ```

            Returns: full address breakdown (street, city, state, country, postcode).

            ### nearby — Find places by category

            ```bash
            # By coordinates (from a Telegram location pin, for example)
            python3 $MAPS nearby 48.8584 2.2945 restaurant --limit 10
            python3 $MAPS nearby 40.7128 -74.0060 hospital --radius 2000

            # By address / city / zip / landmark — --near auto-geocodes
            python3 $MAPS nearby --near "Times Square, New York" --category cafe
            python3 $MAPS nearby --near "90210" --category pharmacy

            # Multiple categories merged into one query
            python3 $MAPS nearby --near "downtown austin" --category restaurant --category bar --limit 10
            ```

            46 categories: restaurant, cafe, bar, hospital, pharmacy, hotel, guest_house,
            camp_site, supermarket, atm, gas_station, parking, museum, park, school,
            university, bank, police, fire_station, library, airport, train_station,
            bus_stop, church, mosque, synagogue, dentist, doctor, cinema, theatre, gym,
            swimming_pool, post_office, convenience_store, bakery, bookshop, laundry,
            car_wash, car_rental, bicycle_rental, taxi, veterinary, zoo, playground,
            stadium, nightclub.

            Each result includes: `name`, `address`, `lat`/`lon`, `distance_m`,
            `maps_url` (clickable Google Maps link), `directions_url` (Google Maps
            directions from the search point), and promoted tags when available —
            `cuisine`, `hours` (opening_hours), `phone`, `website`.

            ### distance — Travel distance and time

            ```bash
            python3 $MAPS distance "Paris" --to "Lyon"
            python3 $MAPS distance "New York" --to "Boston" --mode driving
            python3 $MAPS distance "Big Ben" --to "Tower Bridge" --mode walking
            ```

            Modes: driving (default), walking, cycling. Returns road distance, duration,
            and straight-line distance for comparison.

            ### directions — Turn-by-turn navigation

            ```bash
            python3 $MAPS directions "Eiffel Tower" --to "Louvre Museum" --mode walking
            python3 $MAPS directions "JFK Airport" --to "Times Square" --mode driving
            ```

            Returns numbered steps with instruction, distance, duration, road name, and
            maneuver type (turn, depart, arrive, etc.).

            ### timezone — Timezone for coordinates

            ```bash
            python3 $MAPS timezone 48.8584 2.2945
            python3 $MAPS timezone 35.6762 139.6503
            ```

            Returns timezone name, UTC offset, and current local time.

            ### area — Bounding box and area for a place

            ```bash
            python3 $MAPS area "Manhattan, New York"
            python3 $MAPS area "London"
            ```

            Returns bounding box coordinates, width/height in km, and approximate area.
            Useful as input for the bbox command.

            ### bbox — Search within a bounding box

            ```bash
            python3 $MAPS bbox 40.75 -74.00 40.77 -73.98 restaurant --limit 20
            ```

            Finds POIs within a geographic rectangle. Use `area` first to get the
            bounding box coordinates for a named place.

            ## Working With Telegram Location Pins

            When a user sends a location pin, the message contains `latitude:` and
            `longitude:` fields. Extract those and pass them straight to `nearby`:

            ```bash
            # User sent a pin at 36.17, -115.14 and asked "find cafes nearby"
            python3 $MAPS nearby 36.17 -115.14 cafe --radius 1500
            ```

            Present results as a numbered list with names, distances, and the
            `maps_url` field so the user gets a tap-to-open link in chat. For "open
            now?" questions, check the `hours` field; if missing or unclear, verify
            with `web_search` since OSM hours are community-maintained and not always
            current.

            ## Workflow Examples

            **"Find Italian restaurants near the Colosseum":**
            1. `nearby --near "Colosseum Rome" --category restaurant --radius 500`
               — one command, auto-geocoded

            **"What's near this location pin they sent?":**
            1. Extract lat/lon from the Telegram message
            2. `nearby LAT LON cafe --radius 1500`

            **"How do I walk from hotel to conference center?":**
            1. `directions "Hotel Name" --to "Conference Center" --mode walking`

            **"What restaurants are in downtown Seattle?":**
            1. `area "Downtown Seattle"` → get bounding box
            2. `bbox S W N E restaurant --limit 30`

            ## Pitfalls

            - Nominatim ToS: max 1 req/s (handled automatically by the script)
            - `nearby` requires lat/lon OR `--near "<address>"` — one of the two is needed
            - OSRM routing coverage is best for Europe and North America
            - Overpass API can be slow during peak hours; the script automatically
              falls back between mirrors (overpass-api.de → overpass.kumi.systems)
            - `distance` and `directions` use `--to` flag for the destination (not positional)
            - If a zip code alone gives ambiguous results globally, include country/state

            ## Verification

            ```bash
            python3 ~/.hermes/skills/maps/scripts/maps_client.py search "Statue of Liberty"
            # Should return lat ~40.689, lon ~-74.044

            python3 ~/.hermes/skills/maps/scripts/maps_client.py nearby --near "Times Square" --category restaurant --limit 3
            # Should return a list of restaurants within ~500m of Times Square
            ```

            """#
        ),
        Entry(
            name: "notion",
            description: "Notion API via curl: pages, databases, blocks, search.",
            body: #"""
            ---
            name: notion
            description: "Notion API via curl: pages, databases, blocks, search."
            version: 1.0.0
            author: community
            license: MIT
            metadata:
              hermes:
                tags: [Notion, Productivity, Notes, Database, API]
                homepage: https://developers.notion.com
            prerequisites:
              env_vars: [NOTION_API_KEY]
            ---

            # Notion API

            Use the Notion API via curl to create, read, update pages, databases (data sources), and blocks. No extra tools needed — just curl and a Notion API key.

            ## Prerequisites

            1. Create an integration at https://notion.so/my-integrations
            2. Copy the API key (starts with `ntn_` or `secret_`)
            3. Store it in `~/.hermes/.env`:
               ```
               NOTION_API_KEY=ntn_your_key_here
               ```
            4. **Important:** Share target pages/databases with your integration in Notion (click "..." → "Connect to" → your integration name)

            ## API Basics

            All requests use this pattern:

            ```bash
            curl -s -X GET "https://api.notion.com/v1/..." \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03" \
              -H "Content-Type: application/json"
            ```

            The `Notion-Version` header is required. This skill uses `2025-09-03` (latest). In this version, databases are called "data sources" in the API.

            ## Common Operations

            ### Search

            ```bash
            curl -s -X POST "https://api.notion.com/v1/search" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03" \
              -H "Content-Type: application/json" \
              -d '{"query": "page title"}'
            ```

            ### Get Page

            ```bash
            curl -s "https://api.notion.com/v1/pages/{page_id}" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03"
            ```

            ### Get Page Content (blocks)

            ```bash
            curl -s "https://api.notion.com/v1/blocks/{page_id}/children" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03"
            ```

            ### Create Page in a Database

            ```bash
            curl -s -X POST "https://api.notion.com/v1/pages" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03" \
              -H "Content-Type: application/json" \
              -d '{
                "parent": {"database_id": "xxx"},
                "properties": {
                  "Name": {"title": [{"text": {"content": "New Item"}}]},
                  "Status": {"select": {"name": "Todo"}}
                }
              }'
            ```

            ### Query a Database

            ```bash
            curl -s -X POST "https://api.notion.com/v1/data_sources/{data_source_id}/query" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03" \
              -H "Content-Type: application/json" \
              -d '{
                "filter": {"property": "Status", "select": {"equals": "Active"}},
                "sorts": [{"property": "Date", "direction": "descending"}]
              }'
            ```

            ### Create a Database

            ```bash
            curl -s -X POST "https://api.notion.com/v1/data_sources" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03" \
              -H "Content-Type: application/json" \
              -d '{
                "parent": {"page_id": "xxx"},
                "title": [{"text": {"content": "My Database"}}],
                "properties": {
                  "Name": {"title": {}},
                  "Status": {"select": {"options": [{"name": "Todo"}, {"name": "Done"}]}},
                  "Date": {"date": {}}
                }
              }'
            ```

            ### Update Page Properties

            ```bash
            curl -s -X PATCH "https://api.notion.com/v1/pages/{page_id}" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03" \
              -H "Content-Type: application/json" \
              -d '{"properties": {"Status": {"select": {"name": "Done"}}}}'
            ```

            ### Add Content to a Page

            ```bash
            curl -s -X PATCH "https://api.notion.com/v1/blocks/{page_id}/children" \
              -H "Authorization: Bearer $NOTION_API_KEY" \
              -H "Notion-Version: 2025-09-03" \
              -H "Content-Type: application/json" \
              -d '{
                "children": [
                  {"object": "block", "type": "paragraph", "paragraph": {"rich_text": [{"text": {"content": "Hello from Hermes!"}}]}}
                ]
              }'
            ```

            ## Property Types

            Common property formats for database items:

            - **Title:** `{"title": [{"text": {"content": "..."}}]}`
            - **Rich text:** `{"rich_text": [{"text": {"content": "..."}}]}`
            - **Select:** `{"select": {"name": "Option"}}`
            - **Multi-select:** `{"multi_select": [{"name": "A"}, {"name": "B"}]}`
            - **Date:** `{"date": {"start": "2026-01-15", "end": "2026-01-16"}}`
            - **Checkbox:** `{"checkbox": true}`
            - **Number:** `{"number": 42}`
            - **URL:** `{"url": "https://..."}`
            - **Email:** `{"email": "user@example.com"}`
            - **Relation:** `{"relation": [{"id": "page_id"}]}`

            ## Key Differences in API Version 2025-09-03

            - **Databases → Data Sources:** Use `/data_sources/` endpoints for queries and retrieval
            - **Two IDs:** Each database has both a `database_id` and a `data_source_id`
              - Use `database_id` when creating pages (`parent: {"database_id": "..."}`)
              - Use `data_source_id` when querying (`POST /v1/data_sources/{id}/query`)
            - **Search results:** Databases return as `"object": "data_source"` with their `data_source_id`

            ## Notes

            - Page/database IDs are UUIDs (with or without dashes)
            - Rate limit: ~3 requests/second average
            - The API cannot set database view filters — that's UI-only
            - Use `is_inline: true` when creating data sources to embed them in pages
            - Add `-s` flag to curl to suppress progress bars (cleaner output for Hermes)
            - Pipe output through `jq` for readable JSON: `... | jq '.results[0].properties'`

            """#
        ),
        Entry(
            name: "obsidian",
            description: "Read, search, create, and edit notes in the Obsidian vault.",
            body: #"""
            ---
            name: obsidian
            description: Read, search, create, and edit notes in the Obsidian vault.
            ---

            # Obsidian Vault

            Use this skill for filesystem-first Obsidian vault work: reading notes, listing notes, searching note files, creating notes, appending content, and adding wikilinks.

            ## Vault path

            Use a known or resolved vault path before calling file tools.

            The documented vault-path convention is the `OBSIDIAN_VAULT_PATH` environment variable, for example from `~/.hermes/.env`. If it is unset, use `~/Documents/Obsidian Vault`.

            File tools do not expand shell variables. Do not pass paths containing `$OBSIDIAN_VAULT_PATH` to `read_file`, `write_file`, `patch`, or `search_files`; resolve the vault path first and pass a concrete absolute path. Vault paths may contain spaces, which is another reason to prefer file tools over shell commands.

            If the vault path is unknown, `terminal` is acceptable for resolving `OBSIDIAN_VAULT_PATH` or checking whether the fallback path exists. Once the path is known, switch back to file tools.

            ## Read a note

            Use `read_file` with the resolved absolute path to the note. Prefer this over `cat` because it provides line numbers and pagination.

            ## List notes

            Use `search_files` with `target: "files"` and the resolved vault path. Prefer this over `find` or `ls`.

            - To list all markdown notes, use `pattern: "*.md"` under the vault path.
            - To list a subfolder, search under that subfolder's absolute path.

            ## Search

            Use `search_files` for both filename and content searches. Prefer this over `grep`, `find`, or `ls`.

            - For filenames, use `search_files` with `target: "files"` and a filename `pattern`.
            - For note contents, use `search_files` with `target: "content"`, the content regex as `pattern`, and `file_glob: "*.md"` when you want to restrict matches to markdown notes.

            ## Create a note

            Use `write_file` with the resolved absolute path and the full markdown content. Prefer this over shell heredocs or `echo` because it avoids shell quoting issues and returns structured results.

            ## Append to a note

            Prefer a native file-tool workflow when it is not awkward:

            - Read the target note with `read_file`.
            - Use `patch` for an anchored append when there is stable context, such as adding a section after an existing heading or appending before a known trailing block.
            - Use `write_file` when rewriting the whole note is clearer than constructing a fragile patch.

            For an anchored append with `patch`, replace the anchor with the anchor plus the new content.

            For a simple append with no stable context, `terminal` is acceptable if it is the clearest safe option.

            ## Targeted edits

            Use `patch` for focused note changes when the current content gives you stable context. Prefer this over shell text rewriting.

            ## Wikilinks

            Obsidian links notes with `[[Note Name]]` syntax. When creating notes, use these to link related content.

            """#
        ),
        Entry(
            name: "ocr-and-documents",
            description: "Extract text from PDFs/scans (pymupdf, marker-pdf).",
            body: #"""
            ---
            name: ocr-and-documents
            description: "Extract text from PDFs/scans (pymupdf, marker-pdf)."
            version: 2.3.0
            author: Hermes Agent
            license: MIT
            metadata:
              hermes:
                tags: [PDF, Documents, Research, Arxiv, Text-Extraction, OCR]
                related_skills: [powerpoint]
            ---

            # PDF & Document Extraction

            For DOCX: use `python-docx` (parses actual document structure, far better than OCR).
            For PPTX: see the `powerpoint` skill (uses `python-pptx` with full slide/notes support).
            This skill covers **PDFs and scanned documents**.

            ## Step 1: Remote URL Available?

            If the document has a URL, **always try `web_extract` first**:

            ```
            web_extract(urls=["https://arxiv.org/pdf/2402.03300"])
            web_extract(urls=["https://example.com/report.pdf"])
            ```

            This handles PDF-to-markdown conversion via Firecrawl with no local dependencies.

            Only use local extraction when: the file is local, web_extract fails, or you need batch processing.

            ## Step 2: Choose Local Extractor

            | Feature | pymupdf (~25MB) | marker-pdf (~3-5GB) |
            |---------|-----------------|---------------------|
            | **Text-based PDF** | ✅ | ✅ |
            | **Scanned PDF (OCR)** | ❌ | ✅ (90+ languages) |
            | **Tables** | ✅ (basic) | ✅ (high accuracy) |
            | **Equations / LaTeX** | ❌ | ✅ |
            | **Code blocks** | ❌ | ✅ |
            | **Forms** | ❌ | ✅ |
            | **Headers/footers removal** | ❌ | ✅ |
            | **Reading order detection** | ❌ | ✅ |
            | **Images extraction** | ✅ (embedded) | ✅ (with context) |
            | **Images → text (OCR)** | ❌ | ✅ |
            | **EPUB** | ✅ | ✅ |
            | **Markdown output** | ✅ (via pymupdf4llm) | ✅ (native, higher quality) |
            | **Install size** | ~25MB | ~3-5GB (PyTorch + models) |
            | **Speed** | Instant | ~1-14s/page (CPU), ~0.2s/page (GPU) |

            **Decision**: Use pymupdf unless you need OCR, equations, forms, or complex layout analysis.

            If the user needs marker capabilities but the system lacks ~5GB free disk:
            > "This document needs OCR/advanced extraction (marker-pdf), which requires ~5GB for PyTorch and models. Your system has [X]GB free. Options: free up space, provide a URL so I can use web_extract, or I can try pymupdf which works for text-based PDFs but not scanned documents or equations."

            ---

            ## pymupdf (lightweight)

            ```bash
            pip install pymupdf pymupdf4llm
            ```

            **Via helper script**:
            ```bash
            python scripts/extract_pymupdf.py document.pdf              # Plain text
            python scripts/extract_pymupdf.py document.pdf --markdown    # Markdown
            python scripts/extract_pymupdf.py document.pdf --tables      # Tables
            python scripts/extract_pymupdf.py document.pdf --images out/ # Extract images
            python scripts/extract_pymupdf.py document.pdf --metadata    # Title, author, pages
            python scripts/extract_pymupdf.py document.pdf --pages 0-4   # Specific pages
            ```

            **Inline**:
            ```bash
            python3 -c "
            import pymupdf
            doc = pymupdf.open('document.pdf')
            for page in doc:
                print(page.get_text())
            "
            ```

            ---

            ## marker-pdf (high-quality OCR)

            ```bash
            # Check disk space first
            python scripts/extract_marker.py --check

            pip install marker-pdf
            ```

            **Via helper script**:
            ```bash
            python scripts/extract_marker.py document.pdf                # Markdown
            python scripts/extract_marker.py document.pdf --json         # JSON with metadata
            python scripts/extract_marker.py document.pdf --output_dir out/  # Save images
            python scripts/extract_marker.py scanned.pdf                 # Scanned PDF (OCR)
            python scripts/extract_marker.py document.pdf --use_llm      # LLM-boosted accuracy
            ```

            **CLI** (installed with marker-pdf):
            ```bash
            marker_single document.pdf --output_dir ./output
            marker /path/to/folder --workers 4    # Batch
            ```

            ---

            ## Arxiv Papers

            ```
            # Abstract only (fast)
            web_extract(urls=["https://arxiv.org/abs/2402.03300"])

            # Full paper
            web_extract(urls=["https://arxiv.org/pdf/2402.03300"])

            # Search
            web_search(query="arxiv GRPO reinforcement learning 2026")
            ```

            ## Split, Merge & Search

            pymupdf handles these natively — use `execute_code` or inline Python:

            ```python
            # Split: extract pages 1-5 to a new PDF
            import pymupdf
            doc = pymupdf.open("report.pdf")
            new = pymupdf.open()
            for i in range(5):
                new.insert_pdf(doc, from_page=i, to_page=i)
            new.save("pages_1-5.pdf")
            ```

            ```python
            # Merge multiple PDFs
            import pymupdf
            result = pymupdf.open()
            for path in ["a.pdf", "b.pdf", "c.pdf"]:
                result.insert_pdf(pymupdf.open(path))
            result.save("merged.pdf")
            ```

            ```python
            # Search for text across all pages
            import pymupdf
            doc = pymupdf.open("report.pdf")
            for i, page in enumerate(doc):
                results = page.search_for("revenue")
                if results:
                    print(f"Page {i+1}: {len(results)} match(es)")
                    print(page.get_text("text"))
            ```

            No extra dependencies needed — pymupdf covers split, merge, search, and text extraction in one package.

            ---

            ## Notes

            - `web_extract` is always first choice for URLs
            - pymupdf is the safe default — instant, no models, works everywhere
            - marker-pdf is for OCR, scanned docs, equations, complex layouts — install only when needed
            - Both helper scripts accept `--help` for full usage
            - marker-pdf downloads ~2.5GB of models to `~/.cache/huggingface/` on first use
            - For Word docs: `pip install python-docx` (better than OCR — parses actual structure)
            - For PowerPoint: see the `powerpoint` skill (uses python-pptx)

            """#
        ),
        Entry(
            name: "polymarket",
            description: "Query Polymarket: markets, prices, orderbooks, history.",
            body: #"""
            ---
            name: polymarket
            description: "Query Polymarket: markets, prices, orderbooks, history."
            version: 1.0.0
            author: Hermes Agent + Teknium
            tags: [polymarket, prediction-markets, market-data, trading]
            ---

            # Polymarket — Prediction Market Data

            Query prediction market data from Polymarket using their public REST APIs.
            All endpoints are read-only and require zero authentication.

            See `references/api-endpoints.md` for the full endpoint reference with curl examples.

            ## When to Use

            - User asks about prediction markets, betting odds, or event probabilities
            - User wants to know "what are the odds of X happening?"
            - User asks about Polymarket specifically
            - User wants market prices, orderbook data, or price history
            - User asks to monitor or track prediction market movements

            ## Key Concepts

            - **Events** contain one or more **Markets** (1:many relationship)
            - **Markets** are binary outcomes with Yes/No prices between 0.00 and 1.00
            - Prices ARE probabilities: price 0.65 means the market thinks 65% likely
            - `outcomePrices` field: JSON-encoded array like `["0.80", "0.20"]`
            - `clobTokenIds` field: JSON-encoded array of two token IDs [Yes, No] for price/book queries
            - `conditionId` field: hex string used for price history queries
            - Volume is in USDC (US dollars)

            ## Three Public APIs

            1. **Gamma API** at `gamma-api.polymarket.com` — Discovery, search, browsing
            2. **CLOB API** at `clob.polymarket.com` — Real-time prices, orderbooks, history
            3. **Data API** at `data-api.polymarket.com` — Trades, open interest

            ## Typical Workflow

            When a user asks about prediction market odds:

            1. **Search** using the Gamma API public-search endpoint with their query
            2. **Parse** the response — extract events and their nested markets
            3. **Present** market question, current prices as percentages, and volume
            4. **Deep dive** if asked — use clobTokenIds for orderbook, conditionId for history

            ## Presenting Results

            Format prices as percentages for readability:
            - outcomePrices `["0.652", "0.348"]` becomes "Yes: 65.2%, No: 34.8%"
            - Always show the market question and probability
            - Include volume when available

            Example: `"Will X happen?" — 65.2% Yes ($1.2M volume)`

            ## Parsing Double-Encoded Fields

            The Gamma API returns `outcomePrices`, `outcomes`, and `clobTokenIds` as JSON strings
            inside JSON responses (double-encoded). When processing with Python, parse them with
            `json.loads(market['outcomePrices'])` to get the actual array.

            ## Rate Limits

            Generous — unlikely to hit for normal usage:
            - Gamma: 4,000 requests per 10 seconds (general)
            - CLOB: 9,000 requests per 10 seconds (general)
            - Data: 1,000 requests per 10 seconds (general)

            ## Limitations

            - This skill is read-only — it does not support placing trades
            - Trading requires wallet-based crypto authentication (EIP-712 signatures)
            - Some new markets may have empty price history
            - Geographic restrictions apply to trading but read-only data is globally accessible

            """#
        ),
        Entry(
            name: "powerpoint",
            description: "Create, read, edit .pptx decks, slides, notes, templates.",
            body: #"""
            ---
            name: powerpoint
            description: "Create, read, edit .pptx decks, slides, notes, templates."
            license: Proprietary. LICENSE.txt has complete terms
            ---

            # Powerpoint Skill

            ## When to use

            Use this skill any time a .pptx file is involved in any way — as input, output, or both. This includes: creating slide decks, pitch decks, or presentations; reading, parsing, or extracting text from any .pptx file (even if the extracted content will be used elsewhere, like in an email or summary); editing, modifying, or updating existing presentations; combining or splitting slide files; working with templates, layouts, speaker notes, or comments. Trigger whenever the user mentions "deck," "slides," "presentation," or references a .pptx filename, regardless of what they plan to do with the content afterward. If a .pptx file needs to be opened, created, or touched, use this skill.

            ## Quick Reference

            | Task | Guide |
            |------|-------|
            | Read/analyze content | `python -m markitdown presentation.pptx` |
            | Edit or create from template | Read [editing.md](editing.md) |
            | Create from scratch | Read [pptxgenjs.md](pptxgenjs.md) |

            ---

            ## Reading Content

            ```bash
            # Text extraction
            python -m markitdown presentation.pptx

            # Visual overview
            python scripts/thumbnail.py presentation.pptx

            # Raw XML
            python scripts/office/unpack.py presentation.pptx unpacked/
            ```

            ---

            ## Editing Workflow

            **Read [editing.md](editing.md) for full details.**

            1. Analyze template with `thumbnail.py`
            2. Unpack → manipulate slides → edit content → clean → pack

            ---

            ## Creating from Scratch

            **Read [pptxgenjs.md](pptxgenjs.md) for full details.**

            Use when no template or reference presentation is available.

            ---

            ## Design Ideas

            **Don't create boring slides.** Plain bullets on a white background won't impress anyone. Consider ideas from this list for each slide.

            ### Before Starting

            - **Pick a bold, content-informed color palette**: The palette should feel designed for THIS topic. If swapping your colors into a completely different presentation would still "work," you haven't made specific enough choices.
            - **Dominance over equality**: One color should dominate (60-70% visual weight), with 1-2 supporting tones and one sharp accent. Never give all colors equal weight.
            - **Dark/light contrast**: Dark backgrounds for title + conclusion slides, light for content ("sandwich" structure). Or commit to dark throughout for a premium feel.
            - **Commit to a visual motif**: Pick ONE distinctive element and repeat it — rounded image frames, icons in colored circles, thick single-side borders. Carry it across every slide.

            ### Color Palettes

            Choose colors that match your topic — don't default to generic blue. Use these palettes as inspiration:

            | Theme | Primary | Secondary | Accent |
            |-------|---------|-----------|--------|
            | **Midnight Executive** | `1E2761` (navy) | `CADCFC` (ice blue) | `FFFFFF` (white) |
            | **Forest & Moss** | `2C5F2D` (forest) | `97BC62` (moss) | `F5F5F5` (cream) |
            | **Coral Energy** | `F96167` (coral) | `F9E795` (gold) | `2F3C7E` (navy) |
            | **Warm Terracotta** | `B85042` (terracotta) | `E7E8D1` (sand) | `A7BEAE` (sage) |
            | **Ocean Gradient** | `065A82` (deep blue) | `1C7293` (teal) | `21295C` (midnight) |
            | **Charcoal Minimal** | `36454F` (charcoal) | `F2F2F2` (off-white) | `212121` (black) |
            | **Teal Trust** | `028090` (teal) | `00A896` (seafoam) | `02C39A` (mint) |
            | **Berry & Cream** | `6D2E46` (berry) | `A26769` (dusty rose) | `ECE2D0` (cream) |
            | **Sage Calm** | `84B59F` (sage) | `69A297` (eucalyptus) | `50808E` (slate) |
            | **Cherry Bold** | `990011` (cherry) | `FCF6F5` (off-white) | `2F3C7E` (navy) |

            ### For Each Slide

            **Every slide needs a visual element** — image, chart, icon, or shape. Text-only slides are forgettable.

            **Layout options:**
            - Two-column (text left, illustration on right)
            - Icon + text rows (icon in colored circle, bold header, description below)
            - 2x2 or 2x3 grid (image on one side, grid of content blocks on other)
            - Half-bleed image (full left or right side) with content overlay

            **Data display:**
            - Large stat callouts (big numbers 60-72pt with small labels below)
            - Comparison columns (before/after, pros/cons, side-by-side options)
            - Timeline or process flow (numbered steps, arrows)

            **Visual polish:**
            - Icons in small colored circles next to section headers
            - Italic accent text for key stats or taglines

            ### Typography

            **Choose an interesting font pairing** — don't default to Arial. Pick a header font with personality and pair it with a clean body font.

            | Header Font | Body Font |
            |-------------|-----------|
            | Georgia | Calibri |
            | Arial Black | Arial |
            | Calibri | Calibri Light |
            | Cambria | Calibri |
            | Trebuchet MS | Calibri |
            | Impact | Arial |
            | Palatino | Garamond |
            | Consolas | Calibri |

            | Element | Size |
            |---------|------|
            | Slide title | 36-44pt bold |
            | Section header | 20-24pt bold |
            | Body text | 14-16pt |
            | Captions | 10-12pt muted |

            ### Spacing

            - 0.5" minimum margins
            - 0.3-0.5" between content blocks
            - Leave breathing room—don't fill every inch

            ### Avoid (Common Mistakes)

            - **Don't repeat the same layout** — vary columns, cards, and callouts across slides
            - **Don't center body text** — left-align paragraphs and lists; center only titles
            - **Don't skimp on size contrast** — titles need 36pt+ to stand out from 14-16pt body
            - **Don't default to blue** — pick colors that reflect the specific topic
            - **Don't mix spacing randomly** — choose 0.3" or 0.5" gaps and use consistently
            - **Don't style one slide and leave the rest plain** — commit fully or keep it simple throughout
            - **Don't create text-only slides** — add images, icons, charts, or visual elements; avoid plain title + bullets
            - **Don't forget text box padding** — when aligning lines or shapes with text edges, set `margin: 0` on the text box or offset the shape to account for padding
            - **Don't use low-contrast elements** — icons AND text need strong contrast against the background; avoid light text on light backgrounds or dark text on dark backgrounds
            - **NEVER use accent lines under titles** — these are a hallmark of AI-generated slides; use whitespace or background color instead

            ---

            ## QA (Required)

            **Assume there are problems. Your job is to find them.**

            Your first render is almost never correct. Approach QA as a bug hunt, not a confirmation step. If you found zero issues on first inspection, you weren't looking hard enough.

            ### Content QA

            ```bash
            python -m markitdown output.pptx
            ```

            Check for missing content, typos, wrong order.

            **When using templates, check for leftover placeholder text:**

            ```bash
            python -m markitdown output.pptx | grep -iE "xxxx|lorem|ipsum|this.*(page|slide).*layout"
            ```

            If grep returns results, fix them before declaring success.

            ### Visual QA

            **⚠️ USE SUBAGENTS** — even for 2-3 slides. You've been staring at the code and will see what you expect, not what's there. Subagents have fresh eyes.

            Convert slides to images (see [Converting to Images](#converting-to-images)), then use this prompt:

            ```
            Visually inspect these slides. Assume there are issues — find them.

            Look for:
            - Overlapping elements (text through shapes, lines through words, stacked elements)
            - Text overflow or cut off at edges/box boundaries
            - Decorative lines positioned for single-line text but title wrapped to two lines
            - Source citations or footers colliding with content above
            - Elements too close (< 0.3" gaps) or cards/sections nearly touching
            - Uneven gaps (large empty area in one place, cramped in another)
            - Insufficient margin from slide edges (< 0.5")
            - Columns or similar elements not aligned consistently
            - Low-contrast text (e.g., light gray text on cream-colored background)
            - Low-contrast icons (e.g., dark icons on dark backgrounds without a contrasting circle)
            - Text boxes too narrow causing excessive wrapping
            - Leftover placeholder content

            For each slide, list issues or areas of concern, even if minor.

            Read and analyze these images:
            1. /path/to/slide-01.jpg (Expected: [brief description])
            2. /path/to/slide-02.jpg (Expected: [brief description])

            Report ALL issues found, including minor ones.
            ```

            ### Verification Loop

            1. Generate slides → Convert to images → Inspect
            2. **List issues found** (if none found, look again more critically)
            3. Fix issues
            4. **Re-verify affected slides** — one fix often creates another problem
            5. Repeat until a full pass reveals no new issues

            **Do not declare success until you've completed at least one fix-and-verify cycle.**

            ---

            ## Converting to Images

            Convert presentations to individual slide images for visual inspection:

            ```bash
            python scripts/office/soffice.py --headless --convert-to pdf output.pptx
            pdftoppm -jpeg -r 150 output.pdf slide
            ```

            This creates `slide-01.jpg`, `slide-02.jpg`, etc.

            To re-render specific slides after fixes:

            ```bash
            pdftoppm -jpeg -r 150 -f N -l N output.pdf slide-fixed
            ```

            ---

            ## Dependencies

            - `pip install "markitdown[pptx]"` - text extraction
            - `pip install Pillow` - thumbnail grids
            - `npm install -g pptxgenjs` - creating from scratch
            - LibreOffice (`soffice`) - PDF conversion (auto-configured for sandboxed environments via `scripts/office/soffice.py`)
            - Poppler (`pdftoppm`) - PDF to images

            """#
        ),
        Entry(
            name: "spotify",
            description: "Spotify: play, search, queue, manage playlists and devices.",
            body: #"""
            ---
            name: spotify
            description: "Spotify: play, search, queue, manage playlists and devices."
            version: 1.0.0
            author: Hermes Agent
            license: MIT
            prerequisites:
              tools: [spotify_playback, spotify_devices, spotify_queue, spotify_search, spotify_playlists, spotify_albums, spotify_library]
            metadata:
              hermes:
                tags: [spotify, music, playback, playlists, media]
                related_skills: [gif-search]
            ---

            # Spotify

            Control the user's Spotify account via the Hermes Spotify toolset (7 tools). Setup guide: https://hermes-agent.nousresearch.com/docs/user-guide/features/spotify

            ## When to use this skill

            The user says something like "play X", "pause", "skip", "queue up X", "what's playing", "search for X", "add to my X playlist", "make a playlist", "save this to my library", etc.

            ## The 7 tools

            - `spotify_playback` — play, pause, next, previous, seek, set_repeat, set_shuffle, set_volume, get_state, get_currently_playing, recently_played
            - `spotify_devices` — list, transfer
            - `spotify_queue` — get, add
            - `spotify_search` — search the catalog
            - `spotify_playlists` — list, get, create, add_items, remove_items, update_details
            - `spotify_albums` — get, tracks
            - `spotify_library` — list/save/remove with `kind: "tracks"|"albums"`

            Playback-mutating actions require Spotify Premium; search/library/playlist ops work on Free.

            ## Canonical patterns (minimize tool calls)

            ### "Play <artist/track/album>"
            One search, then play by URI. Do NOT loop through search results describing them unless the user asked for options.

            ```
            spotify_search({"query": "miles davis kind of blue", "types": ["album"], "limit": 1})
            → got album URI spotify:album:1weenld61qoidwYuZ1GESA
            spotify_playback({"action": "play", "context_uri": "spotify:album:1weenld61qoidwYuZ1GESA"})
            ```

            For "play some <artist>" (no specific song), prefer `types: ["artist"]` and play the artist context URI — Spotify handles smart shuffle. If the user says "the song" or "that track", search `types: ["track"]` and pass `uris: [track_uri]` to play.

            ### "What's playing?" / "What am I listening to?"
            Single call — don't chain get_state after get_currently_playing.

            ```
            spotify_playback({"action": "get_currently_playing"})
            ```

            If it returns 204/empty (`is_playing: false`), tell the user nothing is playing. Don't retry.

            ### "Pause" / "Skip" / "Volume 50"
            Direct action, no preflight inspection needed.

            ```
            spotify_playback({"action": "pause"})
            spotify_playback({"action": "next"})
            spotify_playback({"action": "set_volume", "volume_percent": 50})
            ```

            ### "Add to my <playlist name> playlist"
            1. `spotify_playlists list` to find the playlist ID by name
            2. Get the track URI (from currently playing, or search)
            3. `spotify_playlists add_items` with the playlist_id and URIs

            ```
            spotify_playlists({"action": "list"})
            → found "Late Night Jazz" = 37i9dQZF1DX4wta20PHgwo
            spotify_playback({"action": "get_currently_playing"})
            → current track uri = spotify:track:0DiWol3AO6WpXZgp0goxAV
            spotify_playlists({"action": "add_items",
                               "playlist_id": "37i9dQZF1DX4wta20PHgwo",
                               "uris": ["spotify:track:0DiWol3AO6WpXZgp0goxAV"]})
            ```

            ### "Create a playlist called X and add the last 3 songs I played"
            ```
            spotify_playback({"action": "recently_played", "limit": 3})
            spotify_playlists({"action": "create", "name": "Focus 2026"})
            → got playlist_id back in response
            spotify_playlists({"action": "add_items", "playlist_id": <id>, "uris": [<3 uris>]})
            ```

            ### "Save / unsave / is this saved?"
            Use `spotify_library` with the right `kind`.

            ```
            spotify_library({"kind": "tracks", "action": "save", "uris": ["spotify:track:..."]})
            spotify_library({"kind": "albums", "action": "list", "limit": 50})
            ```

            ### "Transfer playback to my <device>"
            ```
            spotify_devices({"action": "list"})
            → pick the device_id by matching name/type
            spotify_devices({"action": "transfer", "device_id": "<id>", "play": true})
            ```

            ## Critical failure modes

            **`403 Forbidden — No active device found`** on any playback action means Spotify isn't running anywhere. Tell the user: "Open Spotify on your phone/desktop/web player first, start any track for a second, then retry." Don't retry the tool call blindly — it will fail the same way. You can call `spotify_devices list` to confirm; an empty list means no active device.

            **`403 Forbidden — Premium required`** means the user is on Free and tried to mutate playback. Don't retry; tell them this action needs Premium. Reads still work (search, playlists, library, get_state).

            **`204 No Content` on `get_currently_playing`** is NOT an error — it means nothing is playing. The tool returns `is_playing: false`. Just report that to the user.

            **`429 Too Many Requests`** = rate limit. Wait and retry once. If it keeps happening, you're looping — stop.

            **`401 Unauthorized` after a retry** — refresh token revoked. Tell the user to run `hermes auth spotify` again.

            ## URI and ID formats

            Spotify uses three interchangeable ID formats. The tools accept all three and normalize:

            - URI: `spotify:track:0DiWol3AO6WpXZgp0goxAV` (preferred)
            - URL: `https://open.spotify.com/track/0DiWol3AO6WpXZgp0goxAV`
            - Bare ID: `0DiWol3AO6WpXZgp0goxAV`

            When in doubt, use full URIs. Search results return URIs in the `uri` field — pass those directly.

            Entity types: `track`, `album`, `artist`, `playlist`, `show`, `episode`. Use the right type for the action — `spotify_playback.play` with a `context_uri` expects album/playlist/artist; `uris` expects an array of track URIs.

            ## What NOT to do

            - **Don't call `get_state` before every action.** Spotify accepts play/pause/skip without preflight. Only inspect state when the user asked "what's playing" or you need to reason about device/track.
            - **Don't describe search results unless asked.** If the user said "play X", search, grab the top URI, play it. They'll hear it's wrong if it's wrong.
            - **Don't retry on `403 Premium required` or `403 No active device`.** Those are permanent until user action.
            - **Don't use `spotify_search` to find a playlist by name** — that searches the public Spotify catalog. User playlists come from `spotify_playlists list`.
            - **Don't mix `kind: "tracks"` with album URIs** in `spotify_library` (or vice versa). The tool normalizes IDs but the API endpoint differs.

            """#
        ),
        Entry(
            name: "youtube-content",
            description: "YouTube transcripts to summaries, threads, blogs.",
            body: #"""
            ---
            name: youtube-content
            description: "YouTube transcripts to summaries, threads, blogs."
            ---

            # YouTube Content Tool

            ## When to use

            Use when the user shares a YouTube URL or video link, asks to summarize a video, requests a transcript, or wants to extract and reformat content from any YouTube video. Transforms transcripts into structured content (chapters, summaries, threads, blog posts).

            Extract transcripts from YouTube videos and convert them into useful formats.

            ## Setup

            ```bash
            pip install youtube-transcript-api
            ```

            ## Helper Script

            `SKILL_DIR` is the directory containing this SKILL.md file. The script accepts any standard YouTube URL format, short links (youtu.be), shorts, embeds, live links, or a raw 11-character video ID.

            ```bash
            # JSON output with metadata
            python3 SKILL_DIR/scripts/fetch_transcript.py "https://youtube.com/watch?v=VIDEO_ID"

            # Plain text (good for piping into further processing)
            python3 SKILL_DIR/scripts/fetch_transcript.py "URL" --text-only

            # With timestamps
            python3 SKILL_DIR/scripts/fetch_transcript.py "URL" --timestamps

            # Specific language with fallback chain
            python3 SKILL_DIR/scripts/fetch_transcript.py "URL" --language tr,en
            ```

            ## Output Formats

            After fetching the transcript, format it based on what the user asks for:

            - **Chapters**: Group by topic shifts, output timestamped chapter list
            - **Summary**: Concise 5-10 sentence overview of the entire video
            - **Chapter summaries**: Chapters with a short paragraph summary for each
            - **Thread**: Twitter/X thread format — numbered posts, each under 280 chars
            - **Blog post**: Full article with title, sections, and key takeaways
            - **Quotes**: Notable quotes with timestamps

            ### Example — Chapters Output

            ```
            00:00 Introduction — host opens with the problem statement
            03:45 Background — prior work and why existing solutions fall short
            12:20 Core method — walkthrough of the proposed approach
            24:10 Results — benchmark comparisons and key takeaways
            31:55 Q&A — audience questions on scalability and next steps
            ```

            ## Workflow

            1. **Fetch** the transcript using the helper script with `--text-only --timestamps`.
            2. **Validate**: confirm the output is non-empty and in the expected language. If empty, retry without `--language` to get any available transcript. If still empty, tell the user the video likely has transcripts disabled.
            3. **Chunk if needed**: if the transcript exceeds ~50K characters, split into overlapping chunks (~40K with 2K overlap) and summarize each chunk before merging.
            4. **Transform** into the requested output format. If the user did not specify a format, default to a summary.
            5. **Verify**: re-read the transformed output to check for coherence, correct timestamps, and completeness before presenting.

            ## Error Handling

            - **Transcript disabled**: tell the user; suggest they check if subtitles are available on the video page.
            - **Private/unavailable video**: relay the error and ask the user to verify the URL.
            - **No matching language**: retry without `--language` to fetch any available transcript, then note the actual language to the user.
            - **Dependency missing**: run `pip install youtube-transcript-api` and retry.

            """#
        ),
    ]
}
