import Foundation

/// A line diff small enough to show what changed and nothing else.
///
/// Equal files return nil, so an unchanged snapshot never becomes model input.
/// The diff is one hunk: the shared start, the changed middle, and the shared end.
public enum LineDiff {
    public static func unified(old: String, new: String, path: String) -> String? {
        if old == new { return nil }
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        let edges = commonEdges(old: oldLines, new: newLines)
        let oldMiddle = oldLines.count - edges.prefix - edges.suffix
        let newMiddle = newLines.count - edges.prefix - edges.suffix

        let context = 3
        let oldStart = max(0, edges.prefix - context)
        let newStart = max(0, edges.prefix - context)
        let oldEnd = min(oldLines.count, oldLines.count - edges.suffix + context)
        let newEnd = min(newLines.count, newLines.count - edges.suffix + context)

        var output = ""
        output += oldLines.isEmpty ? "--- /dev/null\n" : "--- \(path)\n"
        output += "+++ \(path)\n"
        let oldCount = oldEnd - oldStart
        let newCount = newEnd - newStart
        output += "@@ -\(hunkStart(oldStart, count: oldCount)),\(oldCount) +\(hunkStart(newStart, count: newCount)),\(newCount) @@\n"

        let before = edges.prefix - oldStart
        for offset in 0..<before {
            output += " \(oldLines[oldStart + offset])\n"
        }
        if oldMiddle > 0 {
            for offset in 0..<oldMiddle {
                output += "-\(oldLines[edges.prefix + offset])\n"
            }
        }
        if newMiddle > 0 {
            for offset in 0..<newMiddle {
                output += "+\(newLines[edges.prefix + offset])\n"
            }
        }
        let afterStart = oldLines.count - edges.suffix
        let after = oldEnd - afterStart
        for offset in 0..<after {
            output += " \(oldLines[afterStart + offset])\n"
        }
        return output
    }

    static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" {
            parts.removeLast()
        }
        return parts
    }

    private static func commonEdges(old: [String], new: [String]) -> (prefix: Int, suffix: Int) {
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit && old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        return (prefix, suffix)
    }

    private static func hunkStart(_ index: Int, count: Int) -> Int {
        count == 0 ? 0 : index + 1
    }
}
