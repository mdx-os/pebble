import Foundation

/// Decides whether a new snapshot is a real change, and renders that change.
public enum SnapshotDiff {
    /// Text for `modelInput`, or nil when nothing real changed.
    ///
    /// A missing previous snapshot yields the whole normalized text. A later
    /// run yields a line diff. Empty text yields nil so a failed parse cannot
    /// wipe a good snapshot into the model input.
    public static func changedBody(previous: String?, current: String) -> String? {
        let next = SnapshotText.normalize(current)
        guard !next.isEmpty else { return nil }
        guard let previous else { return next }
        let prior = SnapshotText.normalize(previous)
        guard prior != next else { return nil }
        let diff = LineDiff.unified(from: prior, to: next)
        return diff.isEmpty ? next : diff
    }
}

enum LineDiff {
    static func unified(from old: String, to new: String, context: Int = 2) -> String {
        if old == new { return "" }
        let edits = myers(lines(old), lines(new))
        return format(edits, context: context)
    }

    private enum Kind {
        case same
        case insert
        case delete
    }

    private struct Edit {
        var kind: Kind
        var line: String
    }

    private static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), parts.last == "" {
            parts.removeLast()
        }
        return parts
    }

    private static func myers(_ old: [String], _ new: [String]) -> [Edit] {
        let n = old.count
        let m = new.count
        if n == 0 { return new.map { Edit(kind: .insert, line: $0) } }
        if m == 0 { return old.map { Edit(kind: .delete, line: $0) } }

        var v: [Int: Int] = [1: 0]
        var trace: [[Int: Int]] = []
        let max = n + m
        for d in 0...max {
            var k = -d
            while k <= d {
                let x: Int
                if k == -d || (k != d && v[k - 1, default: 0] < v[k + 1, default: 0]) {
                    x = v[k + 1, default: 0]
                } else {
                    x = v[k - 1, default: 0] + 1
                }
                var xPos = x
                var yPos = xPos - k
                while xPos < n, yPos < m, old[xPos] == new[yPos] {
                    xPos += 1
                    yPos += 1
                }
                v[k] = xPos
                if xPos >= n, yPos >= m {
                    trace.append(v)
                    return backtrack(trace, old, new)
                }
                k += 2
            }
            trace.append(v)
        }
        return backtrack(trace, old, new)
    }

    private static func backtrack(_ trace: [[Int: Int]], _ old: [String], _ new: [String]) -> [Edit] {
        var x = old.count
        var y = new.count
        var reversed: [Edit] = []
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[k - 1, default: 0] < v[k + 1, default: 0]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = d == 0 ? 0 : trace[d - 1][prevK, default: 0]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                x -= 1
                y -= 1
                reversed.append(Edit(kind: .same, line: old[x]))
            }
            if d > 0 {
                if x == prevX {
                    y -= 1
                    reversed.append(Edit(kind: .insert, line: new[y]))
                } else {
                    x -= 1
                    reversed.append(Edit(kind: .delete, line: old[x]))
                }
            }
        }
        return reversed.reversed()
    }

    private struct Row {
        var kind: Kind
        var text: String
        var oldNo: Int?
        var newNo: Int?
    }

    private static func format(_ edits: [Edit], context: Int) -> String {
        if edits.allSatisfy({ $0.kind == .same }) { return "" }
        var oldLine = 1
        var newLine = 1
        var rows: [Row] = []
        for edit in edits {
            switch edit.kind {
            case .same:
                rows.append(Row(kind: .same, text: edit.line, oldNo: oldLine, newNo: newLine))
                oldLine += 1
                newLine += 1
            case .delete:
                rows.append(Row(kind: .delete, text: edit.line, oldNo: oldLine, newNo: nil))
                oldLine += 1
            case .insert:
                rows.append(Row(kind: .insert, text: edit.line, oldNo: nil, newNo: newLine))
                newLine += 1
            }
        }
        let changed = rows.indices.filter { rows[$0].kind != .same }
        if changed.isEmpty { return "" }

        var ranges: [Range<Int>] = []
        for index in changed {
            let lower = max(0, index - context)
            let upper = min(rows.count, index + context + 1)
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<upper
            } else {
                ranges.append(lower..<upper)
            }
        }

        var out = ["--- previous", "+++ current"]
        for range in ranges {
            let slice = rows[range]
            let oldStart = slice.compactMap(\.oldNo).first ?? 0
            let newStart = slice.compactMap(\.newNo).first ?? 0
            let oldCount = slice.filter { $0.oldNo != nil }.count
            let newCount = slice.filter { $0.newNo != nil }.count
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            for row in slice {
                let prefix: String
                switch row.kind {
                case .same: prefix = " "
                case .delete: prefix = "-"
                case .insert: prefix = "+"
                }
                out.append(prefix + row.text)
            }
        }
        return out.joined(separator: "\n")
    }
}
