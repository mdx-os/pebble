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

    /// `place` comes from the active model (`ModelClient.privacyPlace`), so
    /// the device promise here is the same one the chat makes. It can change
    /// while the screen is open, as when the cloud is turned on from here,
    /// and the words follow it. With `cloud`, the screen ends with a way
    /// into the cloud setting.
    ///
    /// `onForgetEverything` runs with Forget everything, so whatever else the
    /// agent holds about the person, such as its tasks, goes too. It says
    /// what it forgot, so the status line can be honest about it.
    public init(store: MemoryStore, place: PrivacyPlace, cloud: CloudHelp? = nil,
                onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none }) {
        _model = StateObject(wrappedValue: MemoryModel(store: store, place: place,
                                                       endsCloudChats: Self.endsCloudChats(cloud),
                                                       alsoForget: Self.alsoForget(cloud),
                                                       onForgetEverything: onForgetEverything))
        self.place = place
        self.cloud = cloud
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
    init(model: @autoclosure @escaping () -> MemoryModel, place: PrivacyPlace? = nil, cloud: CloudHelp? = nil) {
        _model = StateObject(wrappedValue: model())
        self.place = place
        self.cloud = cloud
    }

    /// What Forget everything erases besides the notes: the words always
    /// hidden, when there is a cloud setting.
    static func alsoForget(_ cloud: CloudHelp?) -> (@MainActor () throws -> CloudHelp.Forgot)? {
        guard let cloud else { return nil }
        return { try cloud.forgetPrivateWords() }
    }

    /// What Forget everything does before anything else, when there is a
    /// cloud setting: it ends every open cloud chat, and says whether
    /// anything was handed to the cloud this session.
    static func endsCloudChats(_ cloud: CloudHelp?) -> (@MainActor () -> Bool)? {
        guard let cloud else { return nil }
        return { cloud.endOpenCloudChats() }
    }

    /// The Forget everything question's words: they name the private words
    /// whenever there may be some it would erase, those that couldn't be
    /// read included.
    static func forgetEverythingDetail(for cloud: CloudHelp?) -> String {
        cloud?.mayHavePrivateWords == true ? CloudWords.forgetEverythingDetail
            : MemoryWords.forgetEverythingDetail
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
        .modifier(ForgetEverythingDialog(cloud: cloud, isPresented: $model.askForgetEverything) {
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
        }
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
                forgetEverythingButton(shown: model.hasStoredFile || help.mayHavePrivateWords)
            }
        } else {
            forgetEverythingButton(shown: model.hasStoredFile)
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
/// are kept too, whatever else redraws the screen.
private struct ForgetEverythingDialog: ViewModifier {
    let cloud: CloudHelp?
    @Binding var isPresented: Bool
    let forget: @MainActor () -> Void

    func body(content: Content) -> some View {
        if let cloud {
            content.modifier(Watching(help: cloud, isPresented: $isPresented, forget: forget))
        } else {
            Self.dialog(content, isPresented: $isPresented, detail: MemoryView.forgetEverythingDetail(for: nil),
                        forget: forget)
        }
    }

    private struct Watching: ViewModifier {
        @ObservedObject var help: CloudHelp
        @Binding var isPresented: Bool
        let forget: @MainActor () -> Void

        func body(content: Content) -> some View {
            ForgetEverythingDialog.dialog(content, isPresented: $isPresented,
                                          detail: MemoryView.forgetEverythingDetail(for: help), forget: forget)
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
            }
            .padding(Theme.gutter)
            .frame(maxWidth: Theme.readableWidth)
        }
        .confirmationDialog(TaskWords.forgetTasksQuestion, isPresented: $asking, titleVisibility: .visible) {
            Button(TaskWords.forgetTasksTitle, role: .destructive, action: forgetTasks)
            Button(MemoryWords.cancelTitle, role: .cancel) {}
        } message: {
            Text(detail)
        }
    }

    /// What the dialog's button does.
    func forgetTasks() {
        onForgetTasks()
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
    /// Runs first of all: ends every open cloud chat, and says whether
    /// anything was handed to the cloud this session.
    private let endsCloudChats: (@MainActor () -> Bool)?

    /// Forgets what lives outside the memory file, such as tasks.
    private let onForgetEverything: @MainActor () -> ClearedTasks

    init(store: MemoryStore, place: PrivacyPlace, endsCloudChats: (@MainActor () -> Bool)? = nil,
         alsoForget: (@MainActor () throws -> CloudHelp.Forgot)? = nil,
         onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none }) {
        self.store = store
        self.place = place
        self.endsCloudChats = endsCloudChats
        self.alsoForget = alsoForget
        self.onForgetEverything = onForgetEverything
        refresh()
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
        hasStoredFile = store.hasStoredFile
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
        report(try store.remember(newNote, source: .toldMe)) { self.newNote = "" }
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
        report(try store.edit(id, to: editDraft)) { self.cancelEdit() }
    }

    func forget(_ note: MemoryNote) {
        pendingForget = nil
        cancelEdit()
        do {
            if try store.forget(note.id) {
                status = MemoryWords.forgotten
                forgottenCount += 1
            } else {
                status = nil
            }
        } catch {
            status = MemoryWords.couldNotForget
        }
        refresh()
    }

    /// Erases the notes and, whatever happens to them, everything else
    /// Forget everything covers, then says what actually went.
    func forgetEverything() {
        cancelEdit()
        // Before anything is erased, every open cloud chat ends, so no chat
        // still holds what is about to go, and nothing more leaves from one.
        let sent = endsCloudChats?() ?? false
        // Then the tasks, even if the file can't be erased: the person asked
        // to forget, and nothing here depends on the file.
        let tasks = onForgetEverything()
        let notesGone = (try? store.forgetEverything()) != nil
        // nil when there is nothing else; .some(nil) when it couldn't go.
        let rest = alsoForget.map { forget in try? forget() }
        // A step said yes to may have happened, so the line says so here too.
        let underway = tasks.underwayLine.map { " " + $0 } ?? ""
        status = Self.forgotLine(notesGone: notesGone, rest: rest, tasksGone: tasks.forgotten > 0, sent: sent)
            + underway
        let restGone = rest.map { $0 != nil } == true
        if notesGone || restGone || tasks.forgotten > 0 { forgottenCount += 1 }
        refresh()
    }

    /// What Forget everything says went, from what each part did. Tasks
    /// can't fail to go, so they are named only when something else stayed.
    ///
    /// With `sent`, something was handed to the cloud this session, and a
    /// copy of it may be there now. Nothing here can erase that, so the line
    /// never says "I no longer have it", and it ends by saying so plainly.
    static func forgotLine(notesGone: Bool, rest: CloudHelp.Forgot??, tasksGone: Bool, sent: Bool = false) -> String {
        let line = whatWent(notesGone: notesGone, rest: rest, tasksGone: tasksGone)
        guard sent else { return line }
        // Chosen by what went, the same cases `whatWent` reads, not by the
        // words of the line, so no "I no longer have it" can slip through.
        let here = switch (notesGone, rest) {
        case (true, nil), (true, .privateWords?): CloudWords.forgotAfterSending
        case (true, .privateWordsAndCloud?): CloudWords.forgotAndCloudOffAfterSending
        default: line
        }
        return here + " " + CloudWords.sentCantBeErased
    }

    private static func whatWent(notesGone: Bool, rest: CloudHelp.Forgot??, tasksGone: Bool) -> String {
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

    private func report(_ decision: @autoclosure () throws -> MemoryStore.Decision, onSaved: () -> Void) {
        do {
            switch try decision() {
            case .saved: status = MemoryWords.saved(place); savedCount += 1; onSaved()
            case .needsWords: status = MemoryWords.needsWords
            case .tooLong: status = MemoryWords.tooLong
            case .notFound: status = nil; cancelEdit()
            }
        } catch is MemoryStore.Unavailable {
            status = MemoryWords.unavailable
        } catch {
            status = MemoryWords.unreadable
        }
        refresh()
    }
}
#endif
