function claude-dev
    set -l system_prompt "Always write tests, benchmarks, and documentation for any code you produce. When scripting is needed, prefer Python, TypeScript, or another scripting language over Bash — only use Bash as a last resort. When your task involves inspecting, testing, or automating a web application, use Playwright rather than curl or manual HTTP calls. Always use Bun instead of Node.js for running scripts, installing packages, and executing JavaScript or TypeScript. When writing TypeScript, use @types/bun for type definitions instead of @types/node. sudo is passwordless on this machine."
    claude --dangerously-skip-permissions --append-system-prompt $system_prompt $argv
end
