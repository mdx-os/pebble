import Foundation
import PebbleCore

/// Picks how a summary is put together: on this device, unless the model
/// the person chose for new chats runs somewhere else. With the cloud off
/// that model is on the device, so nothing is sent.
public enum ReconSummarizers {
    public static func choose(for model: any ModelClient) -> any ReconSummarizer {
        model.runsOnDevice ? LocalReconSummarizer() : CloudReconSummarizer(model: model)
    }
}

/// Asks the cloud model to summarize what was read, through the same door
/// as every cloud reply: `Conversation` answers words of crisis on this
/// device, and `CloudModel` takes personal details out with `Redactor` and
/// shows the person the exact request before anything leaves.
///
/// The answer is held to the same rule as everything else: a line that
/// doesn't name a source it was given is dropped. If nothing usable comes
/// back, or the person chooses not to send, the summary is put together on
/// this device instead, and says so.
public struct CloudReconSummarizer: ReconSummarizer {
    public let model: any ModelClient

    public init(model: any ModelClient) {
        self.model = model
    }

    public var mayLeaveDevice: Bool { !model.runsOnDevice }

    public func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        let local = LocalReconSummarizer()
        func onDevice(_ note: String?) -> ReconSummary {
            local.summary(task, id: id, sources: sources, gatheredAt: gatheredAt, note: note)
        }
        guard !sources.isEmpty else { return onDevice(nil) }
        let prompt = Self.prompt(for: task, sources: sources)
        // Words of crisis in what would be sent: nothing is sent, and the
        // card says why, never that the person chose it.
        guard !CareCheck.needsCare(prompt) else { return onDevice(ReconWords.keptForCare) }
        let asked = Conversation(turns: [ChatTurn(id: UUID(), speaker: .person, text: prompt)], onDevice: false)
        let reply: String
        do {
            guard let last = try await asked.appendingReply(from: model).turns.last, last.speaker == .agent else {
                return onDevice(ReconWords.cloudUnreadable)
            }
            reply = last.text
        } catch CloudModelError.notSent {
            return onDevice(ReconWords.declinedCloud)
        } catch CloudModelError.withdrawn {
            // Taken away before the person answered. They didn't choose
            // this, so the note doesn't say they did. Only a preview with
            // no answer is withdrawn, so no yes was ever given.
            return onDevice(ReconWords.cloudWithdrawn)
        } catch CloudModelError.off {
            // Off before a preview was shown, or by the time a yes came:
            // nothing was asked, or the yes couldn't be used.
            return onDevice(ReconWords.cloudOff)
        } catch CloudModelError.staysHere {
            return onDevice(ReconWords.keptForCare)
        } catch is CancellationError {
            // Stopped after the yes. Never "nothing went": that isn't known.
            return onDevice(ReconWords.cloudStopped)
        } catch {
            return onDevice(ReconWords.cloudUnavailable)
        }
        return Self.parse(reply, task: task, id: id, sources: sources, gatheredAt: gatheredAt)
            ?? onDevice(ReconWords.cloudUnreadable)
    }

    /// What is sent, before redaction. The person sees it, redacted, in the preview.
    public static func prompt(for task: ReconTask, sources: [ReconSource]) -> String {
        var parts = [
            "Please look into \(task.topic) using only the sources below, and answer in plain words.",
            "Write one line that starts with SUMMARY:, then three to five lines that start with POINT:. If the sources don't agree, add a line that starts with DISAGREE: that says how. End every line with the numbers of the sources it comes from, like [1][3]. Leave out anything the sources don't say.",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        for (index, source) in sources.enumerated() {
            parts.append("[\(index + 1)] \(source.title). \(source.publisher), \(formatter.string(from: source.published)). \(source.url.absoluteString)\n\(source.text)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Reads the answer. Nil when it has no point that names a real source.
    /// Its SUMMARY line is read past, never shown: the overview of a summary
    /// worded in the cloud is the plain one that only says what was read
    /// (see `ReconSummary`).
    public static func parse(_ reply: String, task: ReconTask, id: String, sources: [ReconSource],
                             gatheredAt: Date) -> ReconSummary? {
        guard !sources.isEmpty else { return nil }
        var points: [ReconPoint] = []
        var disagreements: [(String, [String])] = []
        for raw in reply.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let (kind, rest) = label(line) else { continue }
            let (text, ids) = refs(rest, sources: sources)
            guard !text.isEmpty, !ids.isEmpty else { continue }
            switch kind {
            case "SUMMARY": continue
            case "POINT": points.append(ReconPoint(id: "point:\(points.count)", text: text, sourceIDs: ids))
            default: if Set(ids).count >= 2 { disagreements.append((text, ids)) }
            }
        }
        // Each disagreement goes with the point it shares most sources with,
        // or stands as its own point, so it is never lost. A point names
        // only the sources that say it, and a source in the disagreement may
        // be the other side, so the point lets those go and keeps the rest.
        // A point whose only source is in the disagreement keeps it: that is
        // the side it tells. A point that cites more than one side can't say
        // whose words it is, so it never carries the disagreement: it keeps
        // only its sources outside it, or goes if it has none, and the
        // disagreement stands as its own point, naming every side.
        var made = points.count
        func standAlone(_ text: String, _ ids: [String]) {
            points.append(ReconPoint(id: "point:\(made)", text: text, sourceIDs: ids,
                                     disagreement: ReconDisagreement(text: text, sourceIDs: ids)))
            made += 1
        }
        for (text, ids) in disagreements {
            func shared(_ index: Int) -> Int { Set(points[index].sourceIDs).intersection(ids).count }
            guard let best = points.indices.filter({ points[$0].disagreement == nil }).max(by: { shared($0) < shared($1) }),
                  shared(best) > 0 else {
                standAlone(text, ids)
                continue
            }
            let point = points[best]
            let own = point.sourceIDs.filter { !ids.contains($0) }
            if shared(best) == 1 {
                points[best] = ReconPoint(id: point.id, text: point.text, sourceIDs: own.isEmpty ? point.sourceIDs : own,
                                          disagreement: ReconDisagreement(text: text, sourceIDs: ids))
            } else {
                if own.isEmpty {
                    points.remove(at: best)
                } else {
                    points[best] = ReconPoint(id: point.id, text: point.text, sourceIDs: own)
                }
                standAlone(text, ids)
            }
        }
        // The model's own retelling, so the card says where the words came from.
        let summary = ReconSummary(id: id, topic: task.topic, overview: "", points: points, sources: sources,
                                   gatheredAt: gatheredAt, madeOnDevice: false, note: ReconWords.wordedInCloud)
        return summary.points.isEmpty ? nil : summary
    }

    /// The label and the words after it. Only the label itself followed by
    /// a colon counts, so "POINTS:" or "DISAGREEMENT:" never leave "S:" or
    /// "MENT:" on the card.
    private static func label(_ line: String) -> (String, String)? {
        let upper = line.uppercased()
        for kind in ["SUMMARY", "POINT", "DISAGREE"] where upper.hasPrefix(kind + ":") {
            let rest = line.dropFirst(kind.count + 1).drop { $0 == " " }
            return (kind, String(rest))
        }
        return nil
    }

    private static let ref = try! NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)

    /// The line without its source numbers, and the ids of the real ones.
    private static func refs(_ text: String, sources: [ReconSource]) -> (String, [String]) {
        let range = NSRange(text.startIndex..., in: text)
        var ids: [String] = []
        guard !sources.isEmpty else { return (text, ids) }
        for match in ref.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text), let number = Int(text[r]),
                  (1...sources.count).contains(number) else { continue }
            let id = sources[number - 1].id
            if !ids.contains(id) { ids.append(id) }
        }
        let bare = ref.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        return (bare, ids)
    }
}
