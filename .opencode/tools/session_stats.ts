import { existsSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { tool } from "@opencode-ai/plugin"

const toolDirectory = path.dirname(fileURLToPath(import.meta.url))

function findScript(worktree: string) {
  const candidates = [
    process.env.OPENCODE_SESSION_STATS_SCRIPT,
    path.join(worktree, "session-stats.sh"),
    path.resolve(toolDirectory, "../../session-stats.sh"),
    path.resolve(toolDirectory, "../session-stats.sh"),
  ].filter((candidate): candidate is string => Boolean(candidate))

  const script = candidates.find((candidate) => existsSync(candidate))
  if (!script) {
    throw new Error(
      "Could not find session-stats.sh. Place it in the project root, next to the .opencode directory, or set OPENCODE_SESSION_STATS_SCRIPT.",
    )
  }
  return script
}

export default tool({
  description: "Show token, cost, model, tool, and subagent stats for the current opencode session tree.",
  args: {},
  async execute(_args, context) {
    const script = findScript(context.worktree)
    const sessionID = context.sessionID

    if (!sessionID) {
      throw new Error("No current opencode session ID is available in the tool context.")
    }

    return await Bun.$`bash ${script} ${sessionID}`.text()
  },
})
