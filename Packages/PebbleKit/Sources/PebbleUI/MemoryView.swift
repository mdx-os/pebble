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

    /// `place` comes from the active model (`ModelClient.privacyPlace`), so
    /// the device promise here is the same one the chat makes.
    ///
    /// `onForgetEverything` runs with Forget everything, so whatever else the
    /// agent holds about the person, such as its tasks, goes too. It says
    /// what it forgot, so the status line can be honest about it.
    ///
    /// `background` puts its switch here, off until the person turns it on.
    public init(store: MemoryStore, place: PrivacyPlace, background: BackgroundRunner? = nil,
                onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none }) {
        _model = StateObject(wrappedValue: MemoryModel(store: store, place: place, background: background,
                                                       onForgetEverything: onForgetEverything))
    }

    /// Takes a model built from the active model, as `HomeView` does, or
    /// one that already has something to say, for screenshots.
    ///
    /// Load-bearing: `model()` is called inside StateObject's own
    /// autoclosure, so it runs once for the screen, not on every pass of
    /// the view around it. Calling it first would reset "Saved." and a
    /// pending Forget everything on every publish.
    init(model: @autoclosure @escaping () -> MemoryModel) {
        _model = StateObject(wrappedValue: model())
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
                                      nextDue: model.backgroundNext)
                            .padding(.top, 8)
                    }
                    if model.hasStoredFile {
                        Button(role: .destructive) { model.askForgetEverything = true } label: {
                            Text(MemoryWords.forgetEverythingTitle)
                                .font(.subheadline.weight(.semibold))
                                // The system red is about 3.6 to 1 on white.
                                .foregroundStyle(Theme.dangerText)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
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
        .confirmationDialog(
            MemoryWords.forgetEverythingQuestion,
            isPresented: $model.askForgetEverything,
            titleVisibility: .visible
        ) {
            Button(MemoryWords.forgetEverythingTitle, role: .destructive) { model.forgetEverything() }
            Button(MemoryWords.cancelTitle, role: .cancel) {}
        } message: {
            Text(MemoryWords.forgetEverythingDetail)
        }
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
        .onChange(of: scenePhase) { _, phase in
            // Back from a locked screen, look again rather than leave the note up.
            if phase == .active, model.isUnavailable { model.refresh() }
            // And the next summary's day may have moved on meanwhile.
            if phase == .active { model.refreshBackground() }
        }
        .haptic(.saved, trigger: model.savedCount)
        .haptic(.forgotten, trigger: model.forgottenCount)
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

/// The memory screen when the notes couldn't be opened. It says so rather
/// than hide memory; they are only opened again at launch, so the words say
/// that. Forget everything needs the notes, so tasks can be forgotten here
/// on their own, with words that are honest that the notes stay.
struct MemoryUnavailableView: View {
    let hasTasks: Bool
    /// True once every task was forgotten here, until a new one starts.
    var forgotten = false
    /// The line kept while a step said yes to may have happened.
    var underway: String?
    let onForgetTasks: @MainActor () -> Void
    @State private var asking = false
    /// The button goes once the tasks do, so VoiceOver goes to the line
    /// that says what happened rather than nowhere.
    @AccessibilityFocusState private var statusFocused: Bool

    /// What the screen says once the tasks are gone. Nil before then.
    var status: String? {
        guard forgotten, !hasTasks else { return nil }
        return [TaskWords.tasksForgotten, underway].compactMap { $0 }.joined(separator: " ")
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
            Text(TaskWords.forgetTasksDetail)
        }
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
            Toggle(isOn: $isOn) {
                Text(BackgroundWords.settingTitle)
                    .font(.body.weight(.medium))
            }
            // The brand's warmth, as everywhere else, wherever this screen is shown.
            .tint(Theme.accentText)
            .accessibilityIdentifier("backgroundSwitch")
            .accessibilityHint(BackgroundWords.settingDetail(whileClosed: Self.runsWhileClosed))
            Text(BackgroundWords.settingDetail(whileClosed: Self.runsWhileClosed))
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                // Read as the switch's hint, so not twice.
                .accessibilityHidden(true)
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
    /// Whether the words here may promise the device.
    let place: PrivacyPlace
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

    /// Forgets what lives outside the memory file, such as tasks.
    private let onForgetEverything: @MainActor () -> ClearedTasks

    /// Background work, whose switch sits on this screen. Nil hides it.
    let background: BackgroundRunner?
    @Published private(set) var backgroundOn = false
    /// "The next one is due at 7:00 AM tomorrow." while it is on.
    @Published private(set) var backgroundNext: String?
    private let now: () -> Date

    init(store: MemoryStore, place: PrivacyPlace, background: BackgroundRunner? = nil,
         now: @escaping () -> Date = { Date() },
         onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none }) {
        self.store = store
        self.place = place
        self.background = background
        self.now = now
        self.onForgetEverything = onForgetEverything
        refresh()
    }

    /// Turns background work on or off. On, the summary is due the next morning.
    func setBackground(_ on: Bool) {
        guard let background else { return }
        if on { background.turnOn(now: now()) } else { background.turnOff() }
        refreshBackground()
    }

    func refreshBackground() {
        guard let background else { return }
        let on = background.isOn
        if backgroundOn != on { backgroundOn = on }
        let now = now()
        let next = on ? background.queue.map(\.due).min().map { BackgroundWords.nextDue($0, now: now) } : nil
        if backgroundNext != next { backgroundNext = next }
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

    func forgetEverything() {
        cancelEdit()
        // First, and even if the file can't be erased: the person asked to
        // forget, and nothing here depends on the file.
        let tasks = onForgetEverything()
        // A step said yes to may have happened, so the line says so here too.
        let underway = tasks.underwayLine.map { " " + $0 } ?? ""
        do {
            try store.forgetEverything()
            status = MemoryWords.forgotten + underway
            forgottenCount += 1
        } catch {
            // The tasks went even so; the words say which part didn't.
            status = (tasks.forgotten > 0 ? MemoryWords.couldNotForgetNotes : MemoryWords.couldNotForget) + underway
        }
        refresh()
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
