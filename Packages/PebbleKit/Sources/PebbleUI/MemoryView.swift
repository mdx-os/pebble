import Combine
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// Everything the agent remembers, in plain sight. Each note can be changed
/// or erased, and everything can be forgotten at once.
public struct MemoryView: View {
    @StateObject private var model: MemoryModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var addFocused: Bool
    /// Nil keeps the place the model was made with.
    private let place: PrivacyPlace?
    private let cloud: CloudHelp?
    /// True while Forget everything has something besides the notes to
    /// take, such as a receipt, so its button shows with no notes at all.
    private let holdsMore: Bool

    /// `place` comes from the active model (`ModelClient.privacyPlace`), so
    /// the device promise here is the same one the chat makes. It can change
    /// while the screen is open, as when the cloud is turned on from here,
    /// and the words follow it. With `cloud`, the screen ends with a way
    /// into the cloud setting.
    ///
    /// `onForgetEverything` runs with Forget everything, so whatever else the
    /// agent holds about the person, such as its tasks, goes too. It says
    /// what it forgot, so the status line can be honest about it.
    ///
    /// `background` puts its switch here, off until the person turns it on.
    public init(store: MemoryStore, place: PrivacyPlace, cloud: CloudHelp? = nil, background: BackgroundRunner? = nil,
                onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none }) {
        _model = StateObject(wrappedValue: MemoryModel(store: store, place: place, alsoForget: Self.alsoForget(cloud),
                                                       background: background,
                                                       onForgetEverything: onForgetEverything))
        self.place = place
        self.cloud = cloud
        holdsMore = false
    }

    /// Takes a model built from the active model, as `HomeView` does, or
    /// one that already has something to say, for screenshots. With
    /// `place`, the words follow it as it changes; with `cloud`, the screen
    /// ends with a way into the cloud setting, and the model should be
    /// made with the same `cloud` so Forget everything erases its words.
    ///
    /// Load-bearing: `model()` is called inside StateObject's own
    /// autoclosure, so it runs once for the screen, not on every pass of
    /// the view around it. Calling it first would reset "Saved." and a
    /// pending Forget everything on every publish.
    init(model: @autoclosure @escaping () -> MemoryModel, place: PrivacyPlace? = nil, cloud: CloudHelp? = nil,
         holdsMore: Bool = false) {
        _model = StateObject(wrappedValue: model())
        self.place = place
        self.cloud = cloud
        self.holdsMore = holdsMore
    }

    /// Forget everything shows while there is anything for it to take:
    /// notes or morning summaries (`MemoryModel.hasSomethingToForget`),
    /// private words, or something else the agent holds, such as a receipt
    /// with no task left.
    static func showsForgetEverything(hasNotes: Bool, mayHaveWords: Bool, holdsMore: Bool) -> Bool {
        hasNotes || mayHaveWords || holdsMore
    }

    /// What Forget everything erases besides the notes: the words always
    /// hidden, when there is a cloud setting.
    static func alsoForget(_ cloud: CloudHelp?) -> (@MainActor () throws -> CloudHelp.Forgot)? {
        guard let cloud else { return nil }
        return { try cloud.forgetPrivateWords() }
    }

    /// The Forget everything question's words: they name the private words
    /// whenever there may be some it would erase, those that couldn't be
    /// read included, and with `background` the summaries and the switch.
    static func forgetEverythingDetail(for cloud: CloudHelp?, background: Bool = false) -> String {
        switch (cloud?.mayHavePrivateWords == true, background) {
        case (true, true): CloudWords.forgetEverythingWithSummariesDetail
        case (true, false): CloudWords.forgetEverythingDetail
        case (false, let background): MemoryWords.forgetEverythingDetail(background: background)
        }
    }

    public var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    addField
                    if model.isUnreadable {
                        GentleNotice(text: MemoryWords.unreadable)
                    } else if model.isUnavailable {
                        GentleNotice(text: MemoryWords.unavailable, actionTitle: MemoryWords.tryAgainTitle) {
                            model.refresh()
                        }
                    } else if model.notes.isEmpty {
                        empty
                            .transition(.opacity)
                    }
                    if !model.notes.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(model.notes) { note in
                                MemoryRow(
                                    note: note,
                                    isEditing: model.editingID == note.id,
                                    draft: $model.editDraft,
                                    onEdit: { model.beginEdit(note) },
                                    onSave: { model.saveEdit() },
                                    onCancel: { model.cancelEdit() },
                                    onForget: { model.pendingForget = note }
                                )
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                            }
                        }
                    }
                    if model.background != nil {
                        BackgroundRow(isOn: Binding(get: { model.backgroundOn }, set: { model.setBackground($0) }),
                                      detail: model.backgroundDetail, nextDue: model.backgroundNext)
                            .padding(.top, 8)
                    }
                    forgetEverythingSection
                    if let cloud {
                        CloudHelpRow(help: cloud, place: model.place)
                            .padding(.top, 8)
                    }
                    if let status = model.status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 20)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.85), value: model.notes)
        .animation(.easeInOut(duration: 0.2), value: model.editingID)
        .modifier(ForgetEverythingDialog(cloud: cloud, background: model.forgetNamesBackground,
                                         isPresented: $model.askForgetEverything) {
            model.forgetEverything()
        })
        .confirmationDialog(
            MemoryWords.forgetOneQuestion,
            isPresented: Binding(get: { model.pendingForget != nil }, set: { if !$0 { model.pendingForget = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingForget
        ) { note in
            Button(MemoryWords.forgetTitle, role: .destructive) { model.forget(note) }
            Button(MemoryWords.cancelTitle, role: .cancel) {}
        } message: { note in
            Text(note.text)
        }
        .onChange(of: model.statusCount) { _, _ in
            if let status = model.status { AccessibilityNotification.Announcement(status).post() }
        }
        // Private words that couldn't be read at launch, as on a locked
        // device, are read again here, so the question names what it erases.
        .onAppear { cloud?.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Back from a locked screen, look again rather than leave the note up.
            if phase == .active, model.isUnavailable { model.refresh() }
            if phase == .active { cloud?.refresh() }
            // And the next summary's day may have moved on meanwhile.
            if phase == .active { model.refreshBackground() }
        }
        // And while the screen stays open, at the due time and at midnight.
        .task(id: model.backgroundNextChange) { await model.refreshBackgroundAtNextChange() }
        .haptic(.saved, trigger: model.savedCount)
        .haptic(.forgotten, trigger: model.forgottenCount)
        // The flag can change under an open screen; the words follow it.
        .onChange(of: place, initial: true) { _, place in
            if let place { model.place = place }
        }
    }

    @ViewBuilder
    private var forgetEverythingSection: some View {
        if let cloud {
            // Watches the cloud setting, so the button shows while there
            // may be private words to erase.
            CloudWatcher(help: cloud) { help in
                forgetEverythingButton(shown: Self.showsForgetEverything(
                    hasNotes: model.hasSomethingToForget, mayHaveWords: help.mayHavePrivateWords, holdsMore: holdsMore))
            }
        } else {
            forgetEverythingButton(shown: Self.showsForgetEverything(
                hasNotes: model.hasSomethingToForget, mayHaveWords: false, holdsMore: holdsMore))
        }
    }

    @ViewBuilder
    private func forgetEverythingButton(shown: Bool) -> some View {
        if shown {
            Button(role: .destructive) { model.askForgetEverything = true } label: {
                Text(MemoryWords.forgetEverythingTitle)
                    .font(.subheadline.weight(.semibold))
                    // The system red is about 3.6 to 1 on white.
                    .foregroundStyle(Theme.dangerText)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.top, 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MemoryWords.title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Label(MemoryWords.privacyNote(model.place), systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var addField: some View {
        HStack(spacing: 10) {
            TextField(MemoryWords.addPlaceholder, text: $model.newNote, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($addFocused)
                .onSubmit { model.add() }
            Button { model.add() } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle())
                    .pointerHover(in: Circle())
            }
            .buttonStyle(.plain)
            .help(MemoryWords.addTitle)
            .disabled(!model.canAdd || model.newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(MemoryWords.addTitle)
        }
        // Notes that can't be read are left as they are, so nothing new is
        // added on top of them. The notice below says why.
        .disabled(!model.canAdd)
        .opacity(model.canAdd ? 1 : 0.5)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
    }

    private var empty: some View {
        EmptyState(
            symbol: "sparkles",
            title: MemoryWords.emptyTitle,
            detail: MemoryWords.empty(model.place),
            actionTitle: MemoryWords.emptyActionTitle
        ) {
            addFocused = true
        }
    }
}

/// Redraws `content` whenever the cloud setting changes.
private struct CloudWatcher<Content: View>: View {
    @ObservedObject var help: CloudHelp
    @ViewBuilder let content: (CloudHelp) -> Content

    var body: some View { content(help) }
}

/// The Forget everything question. With the cloud setting, its words watch
/// the setting, so they never say "notes and tasks" while private words
/// are kept too, whatever else redraws the screen. With `background`, they
/// name the summaries and the switch it turns off.
private struct ForgetEverythingDialog: ViewModifier {
    let cloud: CloudHelp?
    let background: Bool
    @Binding var isPresented: Bool
    let forget: @MainActor () -> Void

    func body(content: Content) -> some View {
        if let cloud {
            content.modifier(Watching(help: cloud, background: background, isPresented: $isPresented, forget: forget))
        } else {
            Self.dialog(content, isPresented: $isPresented,
                        detail: MemoryView.forgetEverythingDetail(for: nil, background: background), forget: forget)
        }
    }

    private struct Watching: ViewModifier {
        @ObservedObject var help: CloudHelp
        let background: Bool
        @Binding var isPresented: Bool
        let forget: @MainActor () -> Void

        func body(content: Content) -> some View {
            ForgetEverythingDialog.dialog(content, isPresented: $isPresented,
                                          detail: MemoryView.forgetEverythingDetail(for: help, background: background),
                                          forget: forget)
        }
    }

    static func dialog(_ content: some View, isPresented: Binding<Bool>, detail: String,
                       forget: @escaping @MainActor () -> Void) -> some View {
        content.confirmationDialog(MemoryWords.forgetEverythingQuestion, isPresented: isPresented,
                                   titleVisibility: .visible) {
            Button(MemoryWords.forgetEverythingTitle, role: .destructive, action: forget)
            Button(MemoryWords.cancelTitle, role: .cancel) {}
        } message: {
            Text(detail)
        }
    }
}

/// The memory screen when the notes couldn't be opened. It says so rather
/// than hide memory; they are only opened again at launch, so the words say
/// that. Forget everything needs the notes, so tasks can be forgotten here
/// on their own, with words that are honest that the notes stay. With the
/// cloud setting, the words always hidden go with them.
struct MemoryUnavailableView: View {
    /// True while there are tasks, or receipts or tasks kept from before,
    /// to forget. Receipts alone still show the button.
    let hasTasks: Bool
    /// True once every task was forgotten here, until a new one starts.
    var forgotten = false
    /// The line kept while a step said yes to may have happened.
    var underway: String?
    /// What happened to the private words when the tasks went. Nil when
    /// this screen doesn't erase them.
    var wordsErased: CloudHelp.WordsErased?
    /// Whether forgetting here erases the private words too.
    var erasesWords = false
    /// Background work, whose switch and summaries need no notes, so they
    /// are here too. Nil hides them.
    var background: BackgroundRunner?
    let onForgetTasks: @MainActor () -> Void
    @State private var asking = false
    /// The button goes once the tasks do, so VoiceOver goes to the line
    /// that says what happened rather than nowhere.
    @AccessibilityFocusState private var statusFocused: Bool

    /// What the screen says once the tasks are gone. Nil before then.
    var status: String? {
        guard forgotten, !hasTasks else { return nil }
        let went = switch wordsErased {
        case nil: TaskWords.tasksForgotten
        case .erased?: CloudWords.tasksAndWordsForgotten
        case .erasedWithCloud?: CloudWords.tasksAndWordsAndCloudForgotten
        case .stayed?: CloudWords.tasksForgottenNotWords
        }
        return [went, underway].compactMap { $0 }.joined(separator: " ")
    }

    /// The question's words, honest about whether the private words go.
    var detail: String {
        erasesWords ? CloudWords.forgetTasksAndWordsDetail : TaskWords.forgetTasksDetail
    }

    var body: some View {
        ZStack {
            Backdrop()
            // Centred while it fits, and scrolled once the switch and its
            // words make it taller than the screen.
            GeometryReader { space in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, minHeight: space.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .confirmationDialog(TaskWords.forgetTasksQuestion, isPresented: $asking, titleVisibility: .visible) {
            Button(TaskWords.forgetTasksTitle, role: .destructive, action: forgetTasks)
            Button(MemoryWords.cancelTitle, role: .cancel) {}
        } message: {
            Text(detail)
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            GentleNotice(text: MemoryWords.couldNotOpen)
            if hasTasks {
                Button(role: .destructive) { asking = true } label: {
                    Text(TaskWords.forgetTasksTitle)
                        .font(.subheadline.weight(.semibold))
                        // The system red is about 3.6 to 1 on white.
                        .foregroundStyle(Theme.dangerText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("forgetTasks")
            } else if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("tasksForgotten")
                    .accessibilityFocused($statusFocused)
                    .onAppear {
                        // A beat later, once it is on screen; set in
                        // the same pass that adds it, SwiftUI drops it.
                        Task { @MainActor in statusFocused = true }
                    }
            }
            if let background {
                BackgroundFallbackSection(model: BackgroundSettingModel(runner: background))
                    .padding(.top, 8)
            }
        }
        .padding(Theme.gutter)
        .frame(maxWidth: Theme.readableWidth)
    }

    /// What the dialog's button does.
    func forgetTasks() {
        onForgetTasks()
    }
}

/// The switch for background work: what it does in a plain line, and when
/// the next summary is due while it is on.
struct BackgroundRow: View {
    @Binding var isOn: Bool
    /// What the switch does, from `MemoryModel.backgroundDetail`.
    let detail: String
    let nextDue: String?
    @Environment(\.colorScheme) private var scheme

    /// True where the system may give the app time while it is closed.
    /// On the Mac it runs while the app is open, so the line says that.
    static var runsWhileClosed: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One control for the whole row, so the target stays large at
            // any text size and a tap anywhere, the knob included, turns it
            // over exactly once. The switch inside only shows the state.
            Button { isOn.toggle() } label: {
                HStack(spacing: 12) {
                    Text(BackgroundWords.settingTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(BackgroundWords.settingTitle, isOn: .constant(isOn))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        // The brand's warmth, as everywhere else, wherever this screen is shown.
                        .tint(Theme.accentText)
                        .allowsHitTesting(false)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Read as the switch it looks like, with its title and state.
            .accessibilityRepresentation {
                Toggle(BackgroundWords.settingTitle, isOn: $isOn)
            }
            .accessibilityIdentifier("backgroundSwitch")
            // Its own element, read right after the switch, so VoiceOver
            // users hear that it asks first even with hints turned off.
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("backgroundDetail")
            if let nextDue {
                Text(nextDue)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("backgroundNext")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
    }
}

/// What the switch for background work shows, read from its runner, the
/// same on the memory screen and on the one shown when the notes couldn't
/// be opened.
struct BackgroundSetting: Equatable {
    var isOn = false
    /// "I'll look next at 7:00 AM tomorrow." while it is on.
    var next: String?
    /// When `next` next changes its words, so an open screen says it again.
    var nextChange: Date?
    /// True while background work has a file or cards.
    var hasSomethingToForget = false

    init() {}

    init(_ runner: BackgroundRunner, now: Date) {
        isOn = runner.isOn
        let due = isOn ? runner.queue.map(\.due).min() : nil
        next = due.map { BackgroundWords.nextDue($0, now: now) }
        nextChange = due.map { BackgroundWords.nextDueChanges($0, now: now) }
        hasSomethingToForget = runner.store.hasStoredFile || !runner.results.isEmpty
    }

    /// The wait before looking again, in real time.
    static let sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
}

/// The switch for background work, and a way to forget its summaries, on
/// the screen shown when the notes couldn't be opened. The runner keeps its
/// own file, so neither needs the notes. Forget everything isn't there, so
/// the summaries go on their own, and the words say the rest stays.
@MainActor
final class BackgroundSettingModel: ObservableObject {
    let runner: BackgroundRunner
    @Published private(set) var setting = BackgroundSetting()
    @Published var askForget = false
    /// What happened when the summaries were forgotten. Nil before then.
    @Published private(set) var status: String?
    /// Goes up by one each time something was erased, for a light tap.
    @Published private(set) var forgottenCount = 0
    private let now: () -> Date
    private var watch: BackgroundRunner.Observation?
    /// Speaks a line to VoiceOver. Tests listen in.
    var announce: @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    init(runner: BackgroundRunner, now: @escaping () -> Date = { Date() }) {
        self.runner = runner
        self.now = now
        refresh()
        watch = runner.observe { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let watch { runner.stopObserving(watch) }
    }

    var detail: String {
        BackgroundWords.settingDetail(whileClosed: BackgroundRow.runsWhileClosed, countsTasks: runner.tasks != nil)
    }

    /// As on the memory screen: on, VoiceOver hears when it looks next.
    func set(_ on: Bool) {
        if on { runner.turnOn(now: now()) } else { runner.turnOff() }
        refresh()
        if on, let next = setting.next { announce(next) }
    }

    func refresh() {
        let next = BackgroundSetting(runner, now: now())
        if setting != next { setting = next }
    }

    /// As `MemoryModel.refreshBackgroundAtNextChange`.
    func refreshAtNextChange(sleep: (TimeInterval) async throws -> Void = BackgroundSetting.sleep) async {
        guard let next = setting.nextChange else { return }
        while now() < next {
            do { try await sleep(next.timeIntervalSince(now())) } catch { return }
        }
        refresh()
    }

    /// Turns background work off, withdraws what it asked, and erases its
    /// summaries, as Forget everything does for them, then says what went.
    func forget() {
        let erased = (try? runner.forget()) != nil
        status = erased ? MemoryWords.summariesGone : MemoryWords.couldNotForgetSummariesAlone
        if erased { forgottenCount += 1 }
        refresh()
        if let status { announce(status) }
    }
}

/// `BackgroundSettingModel` on screen: the switch, then the button to
/// forget the summaries while there are some, and what that did.
struct BackgroundFallbackSection: View {
    @StateObject private var model: BackgroundSettingModel

    init(model: @autoclosure @escaping () -> BackgroundSettingModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(spacing: 18) {
            BackgroundRow(isOn: Binding(get: { model.setting.isOn }, set: { model.set($0) }),
                          detail: model.detail, nextDue: model.setting.next)
            if model.setting.hasSomethingToForget {
                Button(role: .destructive) { model.askForget = true } label: {
                    Text(MemoryWords.forgetSummariesTitle)
                        .font(.subheadline.weight(.semibold))
                        // The system red is about 3.6 to 1 on white.
                        .foregroundStyle(Theme.dangerText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("forgetSummaries")
            }
            if let status = model.status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("summariesForgotten")
            }
        }
        .confirmationDialog(MemoryWords.forgetSummariesQuestion, isPresented: $model.askForget,
                            titleVisibility: .visible) {
            Button(MemoryWords.forgetSummariesTitle, role: .destructive) { model.forget() }
            Button(MemoryWords.cancelTitle, role: .cancel) {}
        } message: {
            Text(MemoryWords.forgetSummariesDetail)
        }
        .haptic(.forgotten, trigger: model.forgottenCount)
        .task(id: model.setting.nextChange) { await model.refreshAtNextChange() }
    }
}

struct MemoryRow: View {
    let note: MemoryNote
    let isEditing: Bool
    @Binding var draft: String
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onForget: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditing {
                TextField(MemoryWords.editPlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                HStack {
                    Button(MemoryWords.cancelTitle, action: onCancel)
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button(MemoryWords.saveTitle, action: onSave)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(minHeight: 44)
                }
            } else {
                Text(note.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        SourceLabel(source: note.source)
                        Text(note.savedAt, format: .dateTime.month(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    // At large text sizes the source gets its own line so it never clips.
                    VStack(alignment: .leading, spacing: 4) {
                        SourceLabel(source: note.source)
                        Text(note.savedAt, format: .dateTime.month(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                    Spacer(minLength: 0)
                    Button(action: onEdit) { Label(MemoryWords.editTitle, systemImage: "pencil") }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .pointerHover(in: Circle())
                        .help(MemoryWords.editTitle)
                        .accessibilityLabel(MemoryWords.editTitle)
                    Button(role: .destructive, action: onForget) { Label(MemoryWords.forgetTitle, systemImage: "trash") }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .pointerHover(in: Circle())
                        .help(MemoryWords.forgetTitle)
                        .accessibilityLabel(MemoryWords.forgetTitle)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, isEditing ? 6 : 0)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: MemoryWords.editTitle, onEdit)
        .accessibilityAction(named: MemoryWords.forgetTitle, onForget)
    }
}

/// A small label saying where a note came from. Guesses are tinted so they
/// stand out as something to check.
struct SourceLabel: View {
    let source: MemorySource

    var body: some View {
        Label {
            Text(source.label)
                .foregroundStyle(source == .inferred ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.secondaryText))
        } icon: {
            Image(systemName: source.symbol)
                .foregroundStyle(source == .inferred ? AnyShapeStyle(Theme.accentSymbol) : AnyShapeStyle(Theme.secondaryText))
        }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                source == .inferred ? Theme.accent.opacity(Theme.accentWash) : Color.primary.opacity(Theme.fieldTint),
                in: Capsule()
            )
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(source.label)
    }
}

@MainActor
final class MemoryModel: ObservableObject {
    let store: MemoryStore
    /// Whether the words here may promise the device. The screen keeps it
    /// up to date, since turning the cloud on or starting a cloud chat
    /// changes it while the notes stay open.
    @Published var place: PrivacyPlace {
        didSet {
            // A "Saved" line on screen promises what was true when it was
            // said. Say it again with the flag as it is now.
            if place != oldValue, status == MemoryWords.saved(oldValue) { status = MemoryWords.saved(place) }
        }
    }
    @Published private(set) var notes: [MemoryNote] = []
    @Published private(set) var isUnreadable = false
    @Published private(set) var isUnavailable = false
    @Published private(set) var hasStoredFile = false
    @Published var pendingForget: MemoryNote?
    @Published var newNote = ""
    @Published var editingID: UUID?
    @Published var editDraft = ""
    @Published var askForgetEverything = false
    /// What to say about the last thing that happened. Every new line,
    /// even one the same as before, bumps statusCount so it is spoken again.
    @Published private(set) var status: String? {
        didSet { if status != nil { statusCount += 1 } }
    }
    @Published private(set) var statusCount = 0
    /// Go up by one each time a note is saved or forgotten, for a light tap.
    @Published private(set) var savedCount = 0
    @Published private(set) var forgottenCount = 0
    /// Anything else Forget everything erases: the private words, and
    /// sometimes the cloud setting with them.
    private let alsoForget: (@MainActor () throws -> CloudHelp.Forgot)?

    /// Forgets what lives outside the memory file, such as tasks.
    private let onForgetEverything: @MainActor () -> ClearedTasks
    /// True while something else Forget everything erases is on disk, such
    /// as the task engine's file, so the button stays while it is there.
    private let othersStored: @MainActor () -> Bool
    /// Runs after a note is changed or forgotten, so anything showing its
    /// words, such as a kept digest on Today, looks again.
    private let onNotesChanged: @MainActor () -> Void
    /// Runs after a note is forgotten, or changed with its earlier words,
    /// and says whether anything else, such as a kept digest, still holds
    /// them.
    private let forgetQuotes: @MainActor (MemoryNote) -> QuotesForgotten
    private var watchingOthers: AnyCancellable?

    /// Background work, whose switch sits on this screen. Nil hides it.
    let background: BackgroundRunner?
    @Published private(set) var backgroundOn = false
    /// "I'll look next at 7:00 AM tomorrow." while it is on.
    @Published private(set) var backgroundNext: String?
    /// When `backgroundNext` next changes its words.
    @Published private(set) var backgroundNextChange: Date?
    /// True while background work has a file or cards, so Forget everything
    /// shows even with no notes, and the summaries can always be removed.
    @Published private(set) var hasBackgroundToForget = false
    private let now: () -> Date
    /// This model's watch on `background`, so a card made in Today, or the
    /// switch turned in another window, shows here at once.
    private var backgroundWatch: BackgroundRunner.Observation?
    /// Speaks a line to VoiceOver. Tests listen in.
    var announce: @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    /// Forget everything shows while there is anything for it to remove.
    var hasSomethingToForget: Bool { hasStoredFile || hasBackgroundToForget }

    /// Whether the question before Forget everything names work while away:
    /// only while it is on or has summaries to erase, so it promises only
    /// what this tap will do.
    var forgetNamesBackground: Bool { backgroundOn || hasBackgroundToForget }

    /// What the switch does, true for where it runs and for what the runner
    /// counts: what finished is named only when it has tasks to count.
    var backgroundDetail: String {
        BackgroundWords.settingDetail(whileClosed: BackgroundRow.runsWhileClosed,
                                      countsTasks: background?.tasks != nil)
    }

    /// With `othersChanged`, the screen looks again each time it fires, as
    /// when a task elsewhere makes or erases its file, so Forget everything
    /// shows while there is anything to erase.
    init(store: MemoryStore, place: PrivacyPlace, alsoForget: (@MainActor () throws -> CloudHelp.Forgot)? = nil,
         background: BackgroundRunner? = nil, now: @escaping () -> Date = { Date() },
         onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none },
         othersStored: @escaping @MainActor () -> Bool = { false },
         othersChanged: AnyPublisher<Void, Never>? = nil,
         onNotesChanged: @escaping @MainActor () -> Void = {},
         forgetQuotes: @escaping @MainActor (MemoryNote) -> QuotesForgotten = { _ in .notQuoted }) {
        self.store = store
        self.place = place
        self.alsoForget = alsoForget
        self.background = background
        self.now = now
        self.onForgetEverything = onForgetEverything
        self.othersStored = othersStored
        self.onNotesChanged = onNotesChanged
        self.forgetQuotes = forgetQuotes
        refresh()
        watchingOthers = othersChanged?.sink { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        backgroundWatch = background?.observe { [weak self] in
            Task { @MainActor in self?.refreshBackground() }
        }
    }

    deinit {
        if let backgroundWatch { background?.stopObserving(backgroundWatch) }
    }

    /// Turns background work on or off. On, the summary is due the next
    /// morning, and VoiceOver hears when, since the line saying so appears
    /// away from the switch it just turned.
    func setBackground(_ on: Bool) {
        guard let background else { return }
        if on { background.turnOn(now: now()) } else { background.turnOff() }
        refreshBackground()
        if on, let next = backgroundNext { announce(next) }
    }

    func refreshBackground() {
        guard let background else { return }
        let setting = BackgroundSetting(background, now: now())
        if backgroundOn != setting.isOn { backgroundOn = setting.isOn }
        if backgroundNext != setting.next { backgroundNext = setting.next }
        if backgroundNextChange != setting.nextChange { backgroundNextChange = setting.nextChange }
        if hasBackgroundToForget != setting.hasSomethingToForget {
            hasBackgroundToForget = setting.hasSomethingToForget
        }
    }

    /// Waits until the line under the switch changes its words, then says
    /// it again, so "today" never stays up past the time or midnight while
    /// the screen is open. The screen runs it again each time that moment
    /// moves. `sleep` is passed in so tests can move a clock instead.
    func refreshBackgroundAtNextChange(sleep: (TimeInterval) async throws -> Void = BackgroundSetting.sleep) async {
        guard let next = backgroundNextChange else { return }
        while now() < next {
            do { try await sleep(next.timeIntervalSince(now())) } catch { return }
        }
        refreshBackground()
    }

    /// True while a morning summary the runner made is kept: on its cards,
    /// or in a file an earlier Forget everything couldn't erase.
    private var summariesMade: Bool {
        guard let background else { return false }
        // The file first: reading the cards tries the erase again, and the
        // file may be gone after it.
        let kept = ((try? background.store.load())?.results ?? []) + background.results
        return kept.contains { if case .morningSummary = $0.content { true } else { false } }
    }

    func refresh() {
        switch store.contents() {
        case .notes(let all):
            notes = all; isUnreadable = false; isUnavailable = false
        case .unreadable:
            notes = []; isUnreadable = true; isUnavailable = false
        case .unavailable:
            notes = []; isUnreadable = false; isUnavailable = true
        }
        hasStoredFile = store.hasStoredFile || othersStored()
        // Forget everything turns background work off, so the switch follows.
        refreshBackground()
    }

    /// False while the saved notes can't be read or opened, so they stay untouched.
    var canAdd: Bool { !isUnreadable && !isUnavailable }

    /// The store refuses notes it can't read or open, so the words that were
    /// typed stay in the field and the file stays as it was. The screen
    /// refuses first too, as a second guard, so notes it last saw as
    /// unreadable or locked are never written over even if the store
    /// changes how it reads them.
    func add() {
        guard canAdd else {
            status = isUnavailable ? MemoryWords.unavailable : MemoryWords.unreadable
            return
        }
        report(try store.remember(newNote, source: .toldMe)) { _ in self.newNote = "" }
    }

    func beginEdit(_ note: MemoryNote) {
        editDraft = note.text
        editingID = note.id
    }

    func cancelEdit() {
        editingID = nil
        editDraft = ""
    }

    func saveEdit() {
        guard let id = editingID else { return }
        let earlier = notes.first { $0.id == id }
        report(try store.edit(id, to: editDraft)) { note in
            self.cancelEdit()
            // The earlier words go from anything that quoted them, such as
            // a kept digest, or the line says plainly where they stayed.
            if let earlier, earlier.text != note.text {
                switch self.forgetQuotes(earlier) {
                case .stayed: self.status = DigestWords.earlierWordsInDigest
                case .mayHaveStayed: self.status = DigestWords.earlierWordsMayBeInDigest
                case .notQuoted, .forgotten: break
                }
            }
            self.onNotesChanged()
        }
    }

    func forget(_ note: MemoryNote) {
        pendingForget = nil
        cancelEdit()
        do {
            if try store.forget(note.id) {
                // "Gone" only once no kept digest may still hold its words.
                switch forgetQuotes(note) {
                case .stayed: status = DigestWords.stillInDigest
                case .mayHaveStayed: status = DigestWords.mayStillBeInDigest
                case .notQuoted, .forgotten: status = MemoryWords.forgotten
                }
                forgottenCount += 1
            } else {
                status = nil
            }
        } catch {
            status = MemoryWords.couldNotForget
        }
        refresh()
        onNotesChanged()
    }

    /// What happened to the morning summaries with Forget everything.
    /// Work while you're away is off and its cards are gone from the
    /// screen either way; this is about its file.
    enum Summaries: Equatable {
        case erased
        case stayed
    }

    /// Erases the notes and, whatever happens to them, everything else
    /// Forget everything covers, then says what actually went.
    func forgetEverything() {
        cancelEdit()
        // First, and even if a file can't be erased: the person asked to
        // forget, and nothing here depends on the files. Each step runs
        // whatever happened to the ones before it.
        // Background work stops with the tasks it counts, so nothing runs
        // again while the rest goes, and its summaries go. It turns off and
        // its cards go from memory even if its file can't be erased. Before
        // Today's part, so Today redraws with the cards already gone.
        // Summaries erased are named, and tapped for, only when one was
        // made: a file holding only the queue had none to go.
        let hadSummaries = summariesMade
        let summaries = background.map { background -> Summaries in
            (try? background.forget()) != nil ? .erased : .stayed
        }.flatMap { $0 == .erased && !hadSummaries ? nil : $0 }
        let tasks = onForgetEverything()
        // Notes are named as gone only when there were some. Notes that
        // can't be read or opened are there, so they count.
        let hadNotes: Bool
        if case .notes(let all) = store.contents() { hadNotes = !all.isEmpty } else { hadNotes = store.hasStoredFile }
        let notesGone = (try? store.forgetEverything()) != nil
        // nil when there is nothing else; .some(nil) when it couldn't go.
        let rest = alsoForget.map { forget in try? forget() }
        // A step said yes to may have happened, so the line says so here too.
        status = Self.forgotLineWithTasks(notesGone: notesGone, rest: rest, cleared: tasks, summaries: summaries,
                                          hadNotes: hadNotes)
        let restGone = rest.map { $0 != nil } == true
        if notesGone || restGone || (tasks.forgotten > 0 && tasks.erased) || summaries == .erased {
            forgottenCount += 1
        }
        refresh()
    }

    /// The same, with the tasks as the engine left them. Tasks whose file
    /// couldn't be erased are never called gone: the line says so, after
    /// what happened to everything else and before any step that may have
    /// happened.
    static func forgotLineWithTasks(notesGone: Bool, rest: CloudHelp.Forgot??, cleared tasks: ClearedTasks,
                                    summaries: Summaries? = nil, hadNotes: Bool = true) -> String {
        guard !tasks.erased else {
            return forgotLine(notesGone: notesGone, rest: rest, tasksGone: tasks.forgotten > 0, summaries: summaries,
                              underway: tasks.underwayLine, hadNotes: hadNotes)
        }
        let line = forgotLine(notesGone: notesGone, rest: rest, tasksGone: false, summaries: summaries,
                              hadNotes: hadNotes)
        let said: String
        if line == MemoryWords.forgotten {
            said = TaskWords.forgotNotesNotTasks
        } else if MemoryWords.retryAdvice.contains(where: { line.hasSuffix(" " + $0) }) {
            // One ask to try again, last.
            said = beforeRetry(line, [TaskWords.tasksStayed])
        } else {
            said = line + " " + TaskWords.couldNotEraseTasks
        }
        return beforeRetry(said, [tasks.underwayLine].compactMap { $0 })
    }

    /// What Forget everything says went, from what each part did, with
    /// `tasksGone` true only once the tasks and their file went. Tasks are
    /// named only when something else stayed; tasks whose file stayed are
    /// said by `forgotLineWithTasks`.
    /// The summaries are named the same way, and only with background work:
    /// when all the rest went, the line says just what stayed, and when
    /// something else stayed too, a sentence about them follows. Then
    /// `underway`, if a step said yes to may have happened. Any advice to
    /// try again then comes last. Where only the summaries stayed, the
    /// line names only what went: the notes only with `hadNotes`. With
    /// nothing to say of the summaries, `underway` simply follows the line.
    static func forgotLine(notesGone: Bool, rest: CloudHelp.Forgot??, tasksGone: Bool,
                           summaries: Summaries? = nil, underway: String? = nil, hadNotes: Bool = true) -> String {
        let line = notesWordsAndTasksLine(notesGone: notesGone, rest: rest, tasksGone: tasksGone)
        guard let summaries else { return [line, underway].compactMap { $0 }.joined(separator: " ") }
        let restWent = notesGone && (rest.map { $0 != nil } ?? true)
        let said: String
        let aboutSummaries: String?
        switch (summaries, restWent) {
        case (.erased, true):
            said = line; aboutSummaries = nil
        case (.erased, false):
            said = line; aboutSummaries = MemoryWords.summariesGone
        case (.stayed, true):
            said = rest == .some(.some(.privateWordsAndCloud))
                ? CloudWords.forgotAndCloudOffNotSummaries(notes: hadNotes, tasks: tasksGone)
                : MemoryWords.couldNotForgetSummaries(notes: hadNotes, tasks: tasksGone,
                                                      words: rest == .some(.some(.privateWords)))
            aboutSummaries = nil
        case (.stayed, false):
            said = line; aboutSummaries = MemoryWords.summariesStayed
        }
        return beforeRetry(said, [aboutSummaries, underway].compactMap { $0 })
    }

    /// `line` with `sentences` after it, but before its advice to try
    /// again, so that advice is the last thing said.
    private static func beforeRetry(_ line: String, _ sentences: [String]) -> String {
        guard !sentences.isEmpty else { return line }
        let retry = MemoryWords.retryAdvice.first { line.hasSuffix(" " + $0) }
        let body = retry.map { String(line.dropLast($0.count + 1)) } ?? line
        return ([body] + sentences + [retry].compactMap { $0 }).joined(separator: " ")
    }

    /// The line for the notes, the private words and the tasks alone.
    private static func notesWordsAndTasksLine(notesGone: Bool, rest: CloudHelp.Forgot??, tasksGone: Bool) -> String {
        switch (notesGone, rest) {
        case (true, nil), (true, .privateWords?):
            MemoryWords.forgotten
        case (true, .privateWordsAndCloud?):
            CloudWords.forgotAndCloudOff
        case (true, nil?):
            tasksGone ? CloudWords.forgotNotesAndTasksNotWords : CloudWords.forgotNotesNotWords
        case (false, .privateWords?):
            tasksGone ? CloudWords.forgotTasksAndWordsNotNotes : CloudWords.forgotWordsNotNotes
        case (false, .privateWordsAndCloud?):
            tasksGone ? CloudWords.forgotTasksAndWordsAndCloudNotNotes : CloudWords.forgotWordsAndCloudNotNotes
        case (false, nil?):
            tasksGone ? CloudWords.forgotTasksNotNotesOrWords : MemoryWords.couldNotForget
        case (false, nil):
            tasksGone ? MemoryWords.couldNotForgetNotes : MemoryWords.couldNotForget
        }
    }

    private func report(_ decision: @autoclosure () throws -> MemoryStore.Decision, onSaved: (MemoryNote) -> Void) {
        do {
            switch try decision() {
            case .saved(let note): status = MemoryWords.saved(place); savedCount += 1; onSaved(note)
            case .needsWords: status = MemoryWords.needsWords
            case .tooLong: status = MemoryWords.tooLong
            case .notFound: status = nil; cancelEdit()
            }
        } catch is MemoryStore.Unavailable {
            status = MemoryWords.unavailable
        } catch is MemoryStore.Unreadable {
            status = MemoryWords.unreadable
        } catch {
            // Read fine, but the write didn't go through: nothing changed.
            status = MemoryWords.couldNotSave
        }
        refresh()
    }
}
#endif
