import Foundation
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// One task's progress, live. The feed holds tasks without it, so a tick
/// redraws only the card that reads it and never the whole feed.
@MainActor
final class LiveProgress: ObservableObject {
    @Published var value: TaskProgress

    init(_ value: TaskProgress) {
        self.value = value
    }
}

/// What a task's card is in the middle of, kept by `FeedModel` by task id.
/// A card moving from one section to another is a new view, so anything
/// kept in the view itself would be lost: the half typed words, the open
/// field, and where VoiceOver was.
@MainActor
final class TaskCardState: ObservableObject {
    /// The Change course field is open.
    @Published var redirecting = false
    @Published var words = ""
    /// Where VoiceOver goes next. The card takes it once it is on screen,
    /// so a card that just moved sections still gets it.
    @Published var pendingFocus: TaskCard.Focus?
    /// The field had the keyboard when the card moved, so the new card
    /// gives it back.
    var pendingKeyboard = false
    /// The field has the keyboard, as the card last said.
    var typing = false
    /// VoiceOver is on some part of the card, as the card last said.
    var hasVoiceOver = false
    /// A line to show on the card, such as a yes that didn't go through.
    @Published var note: String?

    init() {}

    /// Where VoiceOver should go, once. Nil when nowhere.
    func takeFocus() -> TaskCard.Focus? {
        defer { pendingFocus = nil }
        return pendingFocus
    }

    /// The field opens, and VoiceOver and the keyboard go to it once it is there.
    func openField() {
        redirecting = true
        pendingFocus = .field
        pendingKeyboard = true
    }

    /// The field closes, and VoiceOver goes back to the summary.
    func closeField() {
        words = ""
        redirecting = false
        pendingKeyboard = false
        typing = false
        pendingFocus = .summary
    }
}

/// A live card for long work: what the agent is doing now, how far along it
/// is, the last few steps, and what the person can do about it.
///
/// Approve shows only while the task waits on a yes and its question is
/// pinned in Needs you, and opens the same question sheet as every other
/// question. Change course and Stop never ask. VoiceOver reads the state,
/// the title, the step and the progress as one thought, then each button.
struct TaskCard: View {
    let task: AgentTask
    let time: String
    @ObservedObject var progress: LiveProgress
    /// The field, its words and where focus goes. Held by the feed, so it
    /// outlives this view when the card moves sections.
    @ObservedObject var state: TaskCardState
    /// True only while the task's question is pinned in Needs you. Without
    /// it the card shows the waiting line and no Approve, since nothing
    /// could open the sheet.
    let canApprove: Bool
    /// A scripted example, so the card says so where its buttons are.
    let isSample: Bool
    /// False for work that can't change course, such as looking into one topic.
    let canRedirect: Bool
    let onApprove: () -> Void
    /// Returns false when the engine couldn't take the words, so they stay.
    let onRedirect: (String) -> Bool
    let onStop: () -> Void
    let onRetry: () -> Void
    let onOpen: () -> Void
    let onDismiss: () -> Void

    init(task: AgentTask, time: String, progress: LiveProgress? = nil, state: TaskCardState? = nil,
         canApprove: Bool = false, isSample: Bool = false, canRedirect: Bool = true,
         onApprove: @escaping () -> Void = {}, onRedirect: @escaping (String) -> Bool = { _ in true },
         onStop: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {},
         onOpen: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}) {
        self.task = task
        self.time = time
        _progress = ObservedObject(wrappedValue: progress ?? LiveProgress(task.progress))
        _state = ObservedObject(wrappedValue: state ?? TaskCardState())
        self.canApprove = canApprove
        self.isSample = isSample
        self.canRedirect = canRedirect
        self.onApprove = onApprove
        self.onRedirect = onRedirect
        self.onStop = onStop
        self.onRetry = onRetry
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    enum Focus: Hashable { case summary, field, action(Action) }

    private var redirecting: Bool { state.redirecting }
    @FocusState private var fieldFocused: Bool
    /// Where VoiceOver goes when the redirect field opens and closes, so it
    /// never lands nowhere when a button it was on goes away.
    @AccessibilityFocusState private var focus: Focus?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    }

    private var isLive: Bool { task.state == .running || task.state == .retrying }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            if let note = state.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("taskNote")
            }
            if task.isActive, !task.history.isEmpty {
                history
            }
            if let closing = closingLine {
                Text(closing)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("taskClosing")
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
        // The feed asks for focus when the card moves sections or its task
        // ends. A card that just moved is a new view, so it looks on appear.
        .onAppear(perform: takeSummaryFocus)
        .onChange(of: state.pendingFocus) { _, _ in takeSummaryFocus() }
        .onChange(of: fieldFocused) { _, focused in state.typing = focused }
        .onChange(of: focus) { _, place in state.hasVoiceOver = place != nil }
    }

    /// Takes VoiceOver to the summary a beat later, once the card is in
    /// place; set in the same pass that moves it, SwiftUI drops it.
    private func takeSummaryFocus() {
        guard state.pendingFocus == .summary else { return }
        _ = state.takeFocus()
        Task { @MainActor in focus = .summary }
    }

    /// Takes VoiceOver, and the keyboard if it had it, to the field once it
    /// is on screen.
    private func takeFieldFocus() {
        let voiceOver = state.pendingFocus == .field
        if voiceOver { _ = state.takeFocus() }
        let keyboard = state.pendingKeyboard
        state.pendingKeyboard = false
        guard voiceOver || keyboard else { return }
        Task { @MainActor in
            if keyboard { fieldFocused = true }
            if voiceOver { focus = .field }
        }
    }

    private var asks: Bool { task.state == .waitingOnYou }

    /// Why an ended task left its last step undone, such as "You closed the
    /// question, so I didn't hold a Saturday visit." Its history is gone
    /// from the card once it ends, so this line stays to say so.
    var closingLine: String? {
        guard !task.isActive, let last = task.history.last, last.mark == .skipped else { return nil }
        return last.text
    }

    /// The wrap up's "I didn't ..." line, unless the closing line already
    /// says the one thing that was not done, and that it is that thing.
    /// Told by the step's own mark, never by its words, so a change to how
    /// a closing line reads can't bring the line back twice.
    func showsNotDone(_ wrapUp: TaskWrapUp) -> Bool {
        guard closingLine != nil, let undone = task.history.last?.undone else { return true }
        return wrapUp.notDone != [undone]
    }

    // MARK: What it says

    /// The card's first line for VoiceOver. An example says so first, as it
    /// is seen first.
    var spoken: String {
        [isSample ? FeedWords.exampleMarker : "", task.state.label, task.title, task.step, time]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// The progress, read after the label. Nil once the task has ended.
    var spokenValue: String? {
        guard task.isActive else { return nil }
        var live = task
        live.progress = progress.value
        return live.spokenProgress
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
                            .foregroundStyle(Theme.accentSymbol)
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                if isSample {
                    // The same capsule as the label over an example opened to read.
                    Text(FeedWords.exampleMarker)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(Theme.fieldTint), in: Capsule())
                        .accessibilityIdentifier("exampleTag")
                }
                Spacer(minLength: 8)
                Text(time)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(task.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(task.step)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: task.step)
            if task.isActive && !task.isStuck {
                CalmProgress(progress: progress.value, isLive: isLive)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue(spokenValue ?? "")
        .accessibilityAddTraits(task.isActive ? .updatesFrequently : [])
        .accessibilityFocused($focus, equals: .summary)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keyed by each step, so a new step pushing in never moves
            // words into another row.
            ForEach(task.history.suffix(3), id: \.id) { step in
                Label {
                    Text(step.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Self.symbol(step.mark))
                        .foregroundStyle(Theme.accentSymbol.opacity(0.8))
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
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
            if let notDone = wrapUp.notDoneLine, showsNotDone(wrapUp) {
                Text(notDone)
            }
            if let underway = wrapUp.underwayLine {
                Text(underway)
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

    enum Action: Hashable { case approval, retry, redirect, stop, open, dismiss }

    /// The buttons this card shows, in order. Approve only while waiting on
    /// a yes whose question is pinned in Needs you. An ended card can be
    /// cleared away.
    var actions: [Action] {
        if task.isActive {
            var row: [Action] = []
            if task.waitsForApproval && canApprove { row.append(.approval) }
            if task.isStuck { row.append(.retry) }
            if canRedirect && !redirecting { row.append(.redirect) }
            row.append(.stop)
            return row
        }
        return (task.state == .done && task.result != nil ? [.open] : []) + [.dismiss]
    }

    @ViewBuilder
    private func buttonViews(_ row: [Action]) -> some View {
        ForEach(row, id: \.self) { action in
            button(action)
                // Known, so a card that moves sections can bring VoiceOver along.
                .accessibilityFocused($focus, equals: .action(action))
        }
    }

    @ViewBuilder
    private func button(_ action: Action) -> some View {
        switch action {
        case .approval:
            Button(TaskWords.approveTitle, action: onApprove)
                .buttonStyle(CardButtonStyle(kind: .primary))
        case .retry:
            Button(TaskWords.tryAgainTitle, action: onRetry)
                .buttonStyle(CardButtonStyle(kind: .primary))
        case .redirect:
            Button(TaskWords.redirectTitle) {
                // This button goes away, so VoiceOver and the keyboard
                // go to the field once it appears.
                state.openField()
            }
            .buttonStyle(CardButtonStyle(kind: .secondary))
        case .stop:
            Button(TaskWords.stopTitle, action: onStop)
                .buttonStyle(CardButtonStyle(kind: .quiet))
        case .open:
            Button(FeedWords.openTitle, action: onOpen)
                .buttonStyle(CardButtonStyle(kind: .secondary))
        case .dismiss:
            Button(TaskWords.dismissTitle, action: onDismiss)
                .buttonStyle(CardButtonStyle(kind: .quiet))
        }
    }

    private var redirectField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(TaskWords.redirectPlaceholder, text: $state.words, axis: .vertical)
                .lineLimit(1...3)
                .font(.subheadline)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                // The same neutral field as the chat's, so typed words are
                // on a pair `Theme.textPairs` checks.
                .background(Color.primary.opacity(Theme.fieldTint), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
                .accessibilityLabel(TaskWords.redirectPlaceholder)
                .accessibilityFocused($focus, equals: .field)
                .onAppear(perform: takeFieldFocus)
            HStack(spacing: 8) {
                Button(TaskWords.redirectSendTitle, action: send)
                    .buttonStyle(CardButtonStyle(kind: .primary))
                    .disabled(state.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(TaskWords.redirectCancelTitle, action: closeField)
                    .buttonStyle(CardButtonStyle(kind: .quiet))
            }
        }
    }

    private func send() {
        guard !state.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if onRedirect(state.words) { closeField() }
    }

    /// The field goes away with its buttons, so VoiceOver goes back to the
    /// card's summary, which says what happens now.
    private func closeField() {
        fieldFocused = false
        state.closeField()
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
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? Motion.pressedScale(reduceMotion: reduceMotion) : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
            .pointerHover(in: Capsule())
    }

    // Every pair here is in `Theme.textPairs`, over the card: primary is
    // "onAccent" on "accent", secondary is "accentText" on "accent wash on
    // the card on ...", quiet is "secondaryText" on "card on ...", and a
    // disabled one is "secondaryText" on "disabled button on the card on
    // ...". `TaskCardTests` checks each by name. A button that
    // can't be pressed yet goes quiet gray on a neutral fill, as
    // `AccentButtonStyle` does, rather than fading its words out.
    private var foreground: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(Theme.secondaryText) }
        switch kind {
        // Dark words on the accent fill, as everywhere else, so they read.
        case .primary: return AnyShapeStyle(Theme.onAccent)
        case .secondary: return AnyShapeStyle(Theme.accentText)
        case .quiet: return AnyShapeStyle(Theme.secondaryText)
        }
    }

    private var background: Color {
        guard isEnabled else { return kind == .quiet ? .clear : Color.primary.opacity(Theme.disabledTint) }
        switch kind {
        case .primary: return Theme.accent
        case .secondary: return Theme.accent.opacity(Theme.accentWash)
        case .quiet: return .clear
        }
    }
}
#endif
