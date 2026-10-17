import Foundation
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// A live card for long work: what the agent is doing now, how far along it
/// is, the last few steps, and what the person can do about it.
///
/// Approve shows only while the task waits on a yes, and opens the same
/// question sheet as every other question. Change course and Stop never ask.
/// VoiceOver reads the state, the title, the step and the progress as one
/// thought, then each button.
struct TaskCard: View {
    let task: AgentTask
    let time: String
    var onApprove: () -> Void = {}
    /// Returns false when the engine couldn't take the words, so they stay.
    var onRedirect: (String) -> Bool = { _ in true }
    var onStop: () -> Void = {}
    var onRetry: () -> Void = {}
    var onOpen: () -> Void = {}

    @State private var redirecting = false
    @State private var words = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    }

    private var isLive: Bool { task.state == .running || task.state == .retrying }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            if task.isActive, !task.history.isEmpty {
                history
            }
            if let wrapUp = task.wrapUp {
                wrapUpLines(wrapUp)
            }
            if redirecting && task.isActive {
                redirectField
                    .transition(Motion.arrival(reduceMotion: reduceMotion))
            }
            buttons
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: shape)
        .overlay(shape.stroke(asks ? Theme.accent.opacity(0.55) : Theme.hairline(scheme), lineWidth: asks ? 1.5 : 1))
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.9), value: task.state)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.3), value: redirecting)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task:\(task.id)")
        .onChange(of: task.isActive) { _, active in
            if !active { redirecting = false }
        }
    }

    private var asks: Bool { task.state == .waitingOnYou }

    // MARK: What it says

    /// The card's first line for VoiceOver.
    var spoken: String {
        [task.state.label, task.title, task.step, time].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// The progress, read after the label. Nil once the task has ended.
    var spokenValue: String? {
        task.isActive ? task.spokenProgress : nil
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(task.state.label)
                } icon: {
                    if isLive {
                        LiveDot()
                    } else {
                        Image(systemName: Self.symbol(task.state))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(time)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(task.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(task.step)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: task.step)
            if task.isActive && !task.isStuck {
                CalmProgress(progress: task.progress, isLive: isLive)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue(spokenValue ?? "")
        .accessibilityAddTraits(task.isActive ? .updatesFrequently : [])
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(task.history.suffix(3).enumerated()), id: \.offset) { _, step in
                Label {
                    Text(step.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Self.symbol(step.mark))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 2)
        .accessibilityElement(children: .combine)
    }

    private func wrapUpLines(_ wrapUp: TaskWrapUp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if task.state != .done {
                Text(wrapUp.keptLine)
            }
            if let notDone = wrapUp.notDoneLine {
                Text(notDone)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: What it does

    @ViewBuilder
    private var buttons: some View {
        let row = actions
        if !row.isEmpty {
            // One row when it fits; else the main choice on its own line and
            // the rest beside each other; at the largest text, one per line.
            let lead = Array(row.prefix(1))
            let rest = Array(row.dropFirst())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttonViews(row) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { buttonViews(lead) }
                    HStack(spacing: 8) { buttonViews(rest) }
                }
                VStack(alignment: .leading, spacing: 8) { buttonViews(row) }
            }
            .padding(.top, 2)
        }
    }

    enum Action: Hashable { case approval, retry, redirect, stop, open }

    /// The buttons this card shows, in order. Approve only while waiting on a yes.
    var actions: [Action] {
        if task.isActive {
            var row: [Action] = []
            if task.waitsForApproval { row.append(.approval) }
            if task.isStuck { row.append(.retry) }
            if !redirecting { row.append(.redirect) }
            row.append(.stop)
            return row
        }
        return task.state == .done && task.result != nil ? [.open] : []
    }

    @ViewBuilder
    private func buttonViews(_ row: [Action]) -> some View {
        ForEach(row, id: \.self) { action in
            switch action {
            case .approval:
                Button(TaskWords.approveTitle, action: onApprove)
                    .buttonStyle(CardButtonStyle(kind: .primary))
            case .retry:
                Button(TaskWords.tryAgainTitle, action: onRetry)
                    .buttonStyle(CardButtonStyle(kind: .primary))
            case .redirect:
                Button(TaskWords.redirectTitle) {
                    redirecting = true
                    fieldFocused = true
                }
                .buttonStyle(CardButtonStyle(kind: .secondary))
            case .stop:
                Button(TaskWords.stopTitle, action: onStop)
                    .buttonStyle(CardButtonStyle(kind: .quiet))
            case .open:
                Button(FeedWords.openTitle, action: onOpen)
                    .buttonStyle(CardButtonStyle(kind: .secondary))
            }
        }
    }

    private var redirectField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(TaskWords.redirectPlaceholder, text: $words, axis: .vertical)
                .lineLimit(1...3)
                .font(.subheadline)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
                .accessibilityLabel(TaskWords.redirectPlaceholder)
            HStack(spacing: 8) {
                Button(TaskWords.redirectSendTitle, action: send)
                    .buttonStyle(CardButtonStyle(kind: .primary))
                    .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(TaskWords.redirectCancelTitle) {
                    redirecting = false
                    words = ""
                }
                .buttonStyle(CardButtonStyle(kind: .quiet))
            }
        }
    }

    private func send() {
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if onRedirect(words) {
            words = ""
            redirecting = false
        }
    }

    static func symbol(_ state: TaskState) -> String {
        switch state {
        case .running, .retrying: "circle.fill"
        case .waitingOnYou: "hand.raised.fill"
        case .stalled: "hourglass"
        case .done: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    static func symbol(_ mark: TaskStep.Mark) -> String {
        switch mark {
        case .done: "checkmark"
        case .retried: "arrow.triangle.2.circlepath"
        case .redirected: "arrow.turn.down.right"
        case .skipped: "minus"
        case .approved: "hand.thumbsup"
        }
    }
}

/// The buttons on a task card. Each one at least 44 points tall.
struct CardButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(kind == .quiet ? Theme.hairline(scheme) : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? Motion.pressedScale(reduceMotion: reduceMotion) : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
            .pointerHover(in: Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: Theme.accent
        case .quiet: .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent
        case .secondary: Theme.accent.opacity(0.14)
        case .quiet: .clear
        }
    }
}
#endif
