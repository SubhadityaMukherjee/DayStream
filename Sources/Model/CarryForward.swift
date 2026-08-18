import Foundation

struct CarryResult: Equatable {
    var carriedCount: Int
    var sourceDays: Int
    var skippedAlreadyToday: Int
    var skippedDuplicates: Int

    var summary: String {
        if carriedCount == 0 {
            return "Nothing to carry forward."
        }
        var s = "Carried \(carriedCount) unfinished task\(carriedCount == 1 ? "" : "s") from \(sourceDays) day\(sourceDays == 1 ? "" : "s")."
        if skippedAlreadyToday > 0 {
            s += " Skipped \(skippedAlreadyToday) already on today."
        }
        if skippedDuplicates > 0 {
            s += " Skipped \(skippedDuplicates) duplicate\(skippedDuplicates == 1 ? "" : "s")."
        }
        return s
    }
}

/// Copies all unfinished todos from previous days into today's journal,
/// preserving block structure (ancestor chains + subtrees), skipping DONE
/// subtrees, and skipping anything already present on today.
enum CarryForwardService {

    /// `allFiles` must be sorted newest-first; for tasks appearing on multiple
    /// days, the most recent occurrence wins.
    static func carryForward(allFiles: [(date: Date, text: String)], todayText: String)
        -> (newTodayText: String, result: CarryResult)
    {
        let todayBlocks = BlockTree.parse(todayText)
        let todayKeys = BlockTree.allContentKeys(todayBlocks)

        var seen = Set<String>()
        var carried: [(taskKey: String, pathKeys: [String], pathLines: [String], taskLines: [String])] = []
        var skippedAlreadyToday = 0
        var skippedDuplicates = 0
        var sourceDays = Set<Date>()

        for file in allFiles {
            let blocks = BlockTree.parse(file.text)
            var tasks: [(task: Block, path: [Block])] = []
            BlockTree.collectOpenTasks(blocks, ancestors: [], into: &tasks)
            for entry in tasks {
                let key = BlockTree.normalize(entry.task.content)
                guard !key.isEmpty else { continue }
                if todayKeys.contains(key) {
                    skippedAlreadyToday += 1
                    continue
                }
                if !seen.insert(key).inserted {
                    skippedDuplicates += 1
                    continue
                }
                sourceDays.insert(file.date)
                carried.append((
                    key,
                    entry.path.map { BlockTree.normalize($0.content) },
                    entry.path.map { $0.rawLines.first ?? "" },
                    BlockTree.renderedSubtree(entry.task)
                ))
            }
        }

        guard !carried.isEmpty else {
            return (todayText, CarryResult(
                carriedCount: 0, sourceDays: 0,
                skippedAlreadyToday: skippedAlreadyToday,
                skippedDuplicates: skippedDuplicates))
        }

        // Group tasks sharing an identical ancestor path under one chain copy.
        var groupPathLines: [[String]] = []
        var groupTaskLines: [[String]] = []
        var groupIndexByPath: [[String]: Int] = [:]
        for item in carried {
            if let idx = groupIndexByPath[item.pathKeys] {
                groupTaskLines[idx] += item.taskLines
            } else {
                groupIndexByPath[item.pathKeys] = groupPathLines.count
                groupPathLines.append(item.pathLines)
                groupTaskLines.append(item.taskLines)
            }
        }

        var chunks: [String] = []
        for (pathLines, taskLines) in zip(groupPathLines, groupTaskLines) {
            chunks.append((pathLines + taskLines).joined(separator: "\n"))
        }

        var newText = todayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if newText.isEmpty {
            newText = chunks.joined(separator: "\n\n") + "\n"
        } else {
            newText += "\n\n" + chunks.joined(separator: "\n\n") + "\n"
        }

        let result = CarryResult(
            carriedCount: carried.count,
            sourceDays: sourceDays.count,
            skippedAlreadyToday: skippedAlreadyToday,
            skippedDuplicates: skippedDuplicates
        )
        return (newText, result)
    }
}
