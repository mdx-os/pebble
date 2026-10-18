import Foundation

/// How a kept digest note went.
package enum DigestGone: String, Codable, Equatable, Sendable {
    /// The person, or another writer, removed it.
    case removed
    /// The engine took it out, since no line was left once the notes it
    /// quoted went or changed.
    case tookOut
}

/// A kept digest whose card was put away or let go, as the file keeps it.
/// Ids only: the digest note, the notes with a line in it, in order, and
/// those its last line counts, so a note forgotten later still leaves it,
/// and whether the person changed it. No words, and nothing worked out
/// from them. It goes once the digest note does, so nothing here says
/// how a digest went.
package struct KeptDigest: Codable, Equatable, Sendable {
    package let note: UUID
    package var quoted: [UUID]?
    package var more: [UUID]?
    package var byHand: Bool

    package init(note: UUID, quoted: [UUID]?, more: [UUID]?, byHand: Bool) {
        self.note = note
        self.quoted = quoted
        self.more = more
        self.byHand = byHand
    }
}

/// What the on-device task engine keeps in `TaskStore`: every task, the
/// kept digests let go, and how and when the tasks whose cards went had
/// ended, for the morning summary.
package struct StoredFile: Codable, Equatable, Sendable {
    package let tasks: [StoredTask]
    package let kept: [KeptDigest]?
    /// States and times only, for a week. Absent when there are none.
    package let ended: [TaskEnd]?

    package init(tasks: [StoredTask], kept: [KeptDigest]?, ended: [TaskEnd]? = nil) {
        self.tasks = tasks
        self.kept = kept
        self.ended = ended
    }
}

/// A task as the store keeps it: what its card shows, whether a save the
/// person said yes to was under way, and for a kept digest, which notes
/// to read its words from. Never a note's words. Its history does keep
/// the person's own instructions, as they typed them to change course,
/// until the card is put away or Forget everything erases the file.
package struct StoredTask: Codable, Equatable, Sendable {
    package struct Step: Codable, Equatable, Sendable {
        let text: String
        let mark: String
        let at: Date
    }

    package struct WrapUp: Codable, Equatable, Sendable {
        let kept: [String]
        let notDone: [String]
        let underway: String?
    }

    package let id: String
    let title: String
    let step: String
    let state: String
    let history: [Step]
    let wrapUp: WrapUp?
    let startedAt: Date
    let updatedAt: Date
    /// The person said yes and the note was being written.
    package let saving: Bool
    /// The note the digest was kept as.
    package let kept: UUID?
    /// The notes a kept digest drew from.
    package let drewFrom: [UUID]?
    /// The notes with a line in a kept digest, in order, and those its
    /// last line counts, so a forgotten note's line can be taken out.
    package let quoted: [UUID]?
    package let more: [UUID]?
    /// True once the person changed the kept digest, so it is left as
    /// theirs. Absent otherwise.
    package let byHand: Bool?
    /// True once a note the kept digest drew from went while the digest
    /// may still hold its words. Absent otherwise.
    package let hidesQuote: Bool?
    /// How the kept digest note went, once it has, with no id left.
    package let gone: DigestGone?

    package init(_ task: AgentTask, saving: Bool, kept: UUID? = nil, drewFrom: [UUID] = [], quoted: [UUID]? = nil,
                 more: [UUID]? = nil, byHand: Bool = false, hidesQuote: Bool = false, gone: DigestGone? = nil) {
        id = task.id
        title = task.title
        step = task.step
        state = task.state.rawValue
        history = task.history.map { Step(text: $0.text, mark: $0.mark.rawValue, at: $0.at) }
        wrapUp = task.wrapUp.map { WrapUp(kept: $0.kept, notDone: $0.notDone, underway: $0.underway) }
        startedAt = task.startedAt
        updatedAt = task.updatedAt
        self.saving = saving
        self.kept = kept
        self.drewFrom = kept == nil ? nil : drewFrom
        self.quoted = kept == nil ? nil : quoted
        self.more = kept == nil ? nil : more
        self.byHand = kept != nil && byHand ? true : nil
        self.hidesQuote = kept != nil && hidesQuote ? true : nil
        self.gone = gone
    }

    /// True when it had ended, so it comes back as it was.
    package var hadEnded: Bool { TaskState(rawValue: state)?.isFinished == true }

    /// The task as it comes back after the app closed. One that ended
    /// comes back as it was, full only if it was done. One that was still
    /// going comes back stopped, never done, and a save said yes to may be
    /// done.
    package func restored(at now: Date) -> AgentTask {
        let steps = history.map { TaskStep($0.text, mark: TaskStep.Mark(rawValue: $0.mark) ?? .done, at: $0.at) }
        let state = TaskState(rawValue: self.state) ?? .stopped
        guard !state.isFinished else {
            return AgentTask(id: id, title: title, step: step, progress: state == .done ? .fraction(1) : .indeterminate,
                             state: state, history: steps,
                             wrapUp: wrapUp.map { TaskWrapUp(kept: $0.kept, notDone: $0.notDone, underway: $0.underway) },
                             startedAt: startedAt, updatedAt: updatedAt)
        }
        return AgentTask(id: id, title: title, step: DigestWords.stoppedWhenClosed, progress: .indeterminate,
                         state: .stopped, history: steps,
                         wrapUp: TaskWrapUp(kept: [], notDone: saving ? [] : [DigestTask.saveTodo],
                                            underway: saving ? DigestTask.saveTodo : nil),
                         startedAt: startedAt, updatedAt: now)
    }
}
