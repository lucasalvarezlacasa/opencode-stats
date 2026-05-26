# opencode-session-stats

Extract full token usage, cost, model breakdown, tool usage, and timing for an opencode session including all its subagent child sessions.

## Motivation

OpenCode's built-in session stats only show token usage for the **root session**. When the [Task tool](https://opencode.ai) spawns subagents, each subagent runs in its own child session with its own token usage, model calls, and tool invocations. OpenCode has no built-in way to aggregate stats across the full session tree. Sessions using many subagents often appear deceptively cheap in the built-in stats.

This script recursively crawls the parent-child session tree to report the **total cost** of a session, including every subagent launched during it.

## How it works

OpenCode stores session data in a local SQLite database. When the Task tool spawns a subagent, it creates a **child session** linked via `parent_id`. This script uses recursive CTEs to walk the full session tree from a given root and aggregate statistics across all child sessions.

## Requirements

- `sqlite3` CLI with JSON output mode and JSON1 support (SQLite 3.38+ recommended)
- Optional: `jq` for prettier JSON output
- Optional: `opencode` CLI for automatic DB path discovery

## Usage

```bash
# Make the script executable if needed
chmod +x session-stats.sh

# List recent root sessions
./session-stats.sh --list

# Stats for a specific session (table format)
./session-stats.sh ses_01JXY...

# Stats as JSON
./session-stats.sh --json ses_01JXY...

# Stats for the most recent root session
./session-stats.sh --latest

# Override the database path
./session-stats.sh --db ~/.local/share/opencode/opencode.db ses_01JXY...
```

## opencode integration

This repository also includes an optional opencode integration that adds a `/stats` command inside the opencode TUI.

When you run `/stats`, opencode calls the `session_stats` custom tool. The tool reads the current opencode session ID from the tool execution context and runs:

```bash
bash session-stats.sh <current-session-id>
```

The output is the same human-readable table format as the standalone script. The command does not expose a JSON mode; it is intended for quickly checking the cost, token usage, model breakdown, tool usage, and subagent session tree for the session you currently have open.

### Install per project

Copy the `.opencode/` directory and `session-stats.sh` into the root of the project where you run opencode:

```text
your-project/
  session-stats.sh
  .opencode/
    commands/
      stats.md
    tools/
      session_stats.ts
```

Then restart opencode from that project and run:

```text
/stats
```

### Install globally

Run the installer from this repository:

```bash
./install.sh
```

It copies the command, tool, and script into your global opencode config directory:

```text
~/.config/opencode/
  commands/
    stats.md
  tools/
    session_stats.ts
  session-stats.sh
```

Then restart opencode and run:

```text
/stats
```

The installer uses `~/.config/opencode` by default. To install into a custom opencode config directory, set `OPENCODE_CONFIG_DIR`:

```bash
OPENCODE_CONFIG_DIR=/path/to/opencode-config ./install.sh
```

Manual global installation is also possible: copy `.opencode/commands/stats.md`, `.opencode/tools/session_stats.ts`, and `session-stats.sh` into the same paths shown above.

Restart opencode after installing or changing command/tool files. opencode loads these files at startup.

### Requirements

- `sqlite3` CLI with JSON output mode and JSON1 support
- opencode custom tools support
- `session-stats.sh` available through one of the tool's lookup paths: `OPENCODE_SESSION_STATS_SCRIPT`, the current project root (`./session-stats.sh`), next to the project `.opencode/` directory when copying this repository layout, or the global config directory (`~/.config/opencode/session-stats.sh`)

## Output sections

| Section | Description |
|---------|-------------|
| **Session Overview** | Tree size, message count, wall time |
| **Cost & Tokens** | Aggregated cost and token breakdown (input, output, reasoning, cache read/write) |
| **Model Breakdown** | Per-agent/model usage: messages, cost, tokens |
| **Tool Usage** | Histogram of tool invocations across the tree |
| **Session Tree** | Visual tree of parent + child sessions with per-node totals |

## Database location

The script discovers the DB automatically:
1. Runs `opencode db path` if the CLI is available
2. Falls back to `$XDG_DATA_HOME/opencode/opencode.db` (typically `~/.local/share/opencode/opencode.db`)
3. Can be overridden with `--db PATH`

## Notes

- The script is read-only: it queries the local opencode database and does not modify it.
- Token counts on the `session` row are **per-session only** (not recursive). The script sums them across the tree.
- "Wall time" is derived from `time_created` of the earliest session to `time_updated` of the latest in the tree — it's a rough upper bound, not active computation time.
- The model breakdown uses per-message JSON data (`message.data`) which includes per-turn cost and tokens reported by the LLM provider.
- Session IDs are validated before querying SQLite and must use the normal `ses_...` opencode format.
