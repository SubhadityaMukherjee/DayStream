import Foundation

/// Git-backed vault backup via the git CLI. Used by Settings → Advanced.
/// Runs `git add -A`, commits with a fixed message, and pushes to the
/// configured remote. `GIT_TERMINAL_PROMPT=0` makes git fail instead of
/// hanging on credential prompts.
enum GitBackup {
    struct Result: Equatable {
        var success: Bool
        var message: String
    }

    static let commitMessage = "backing up files"

    /// Absolute path to git, or nil when it isn't installed.
    static let gitURL: URL? = {
        for path in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }()

    static var gitAvailable: Bool { gitURL != nil }

    static func isGitRepo(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// The first git repository at or above `url` (vault itself, or a parent
    /// folder that contains the vault). Searches up to 4 levels.
    static func containingRepo(for url: URL) -> URL? {
        var current = url
        for _ in 0..<4 {
            if isGitRepo(current) { return current }
            guard current.pathComponents.count > 1 else { break }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// add -A → commit → push. Reports a combined, user-facing message.
    static func backup(repo: URL) -> Result {
        guard let git = gitURL else {
            return Result(success: false, message: "git is not installed. Install Xcode Command Line Tools (xcode-select --install) or git itself, then try again.")
        }
        guard isGitRepo(repo) else {
            return Result(success: false, message: "“\(repo.path)” is not a git repository. Pick the folder that contains the .git directory (it may be a parent of your vault).")
        }

        guard let add = run(["add", "-A"], git: git, in: repo) else {
            return Result(success: false, message: "Could not run git (add failed).")
        }
        guard add.code == 0 else {
            return Result(success: false, message: "git add failed:\n\(tail(add.output))")
        }

        var notes: [String] = []
        if let commit = run(["commit", "-m", commitMessage], git: git, in: repo) {
            if commit.code == 0 {
                notes.append("Changes committed.")
            } else if commit.output.lowercased().contains("nothing to commit") {
                notes.append("Nothing new to commit.")
            } else {
                return Result(success: false, message: "git commit failed:\n\(tail(commit.output))")
            }
        }

        guard let push = run(["push"], git: git, in: repo) else {
            return Result(success: false, message: "Could not run git (push failed).")
        }
        guard push.code == 0 else {
            return Result(success: false, message: "\(notes.joined(separator: " ")) Push failed:\n\(tail(push.output))\n\nCheck that the repository has a remote and that your credentials (SSH key or HTTPS credential helper) are set up.")
        }
        notes.append("Pushed to the remote.")
        return Result(success: true, message: notes.joined(separator: " "))
    }

    /// Last ~400 characters of git output, for error popups.
    private static func tail(_ output: String) -> String {
        guard output.count > 400 else { return output }
        return "…" + String(output.suffix(400))
    }

    @discardableResult
    private static func run(_ args: [String], git: URL, in dir: URL) -> (code: Int32, output: String)? {
        let process = Process()
        process.executableURL = git
        process.currentDirectoryURL = dir
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
