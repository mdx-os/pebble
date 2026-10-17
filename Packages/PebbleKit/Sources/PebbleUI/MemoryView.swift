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
    private let cloud: CloudHelp?

    /// With `cloud`, the screen ends with a way into the cloud setting.
    public init(store: MemoryStore, cloud: CloudHelp? = nil) {
        _model = StateObject(wrappedValue: MemoryModel(store: store))
        self.cloud = cloud
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
                    if model.hasStoredFile {
                        Button(role: .destructive) { model.askForgetEverything = true } label: {
                            Text(MemoryWords.forgetEverythingTitle)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .padding(.top, 8)
                    }
                    if let cloud {
                        CloudHelpRow(help: cloud)
                            .padding(.top, 8)
                    }
                    if let status = model.status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
        }
        .haptic(.saved, trigger: model.savedCount)
        .haptic(.forgotten, trigger: model.forgottenCount)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MemoryWords.title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Label(MemoryWords.privacyNote, systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.white)
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
            detail: MemoryWords.empty,
            actionTitle: MemoryWords.emptyActionTitle
        ) {
            addFocused = true
        }
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
                        .foregroundStyle(Theme.accent)
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
                            .foregroundStyle(.tertiary)
                    }
                    // At large text sizes the source gets its own line so it never clips.
                    VStack(alignment: .leading, spacing: 4) {
                        SourceLabel(source: note.source)
                        Text(note.savedAt, format: .dateTime.month(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
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
                .foregroundStyle(source == .inferred ? Color.primary : Color.secondary)
        } icon: {
            Image(systemName: source.symbol)
                .foregroundStyle(source == .inferred ? Theme.accent : .secondary)
        }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (source == .inferred ? Theme.accent : Color.secondary).opacity(0.12),
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

    init(store: MemoryStore) {
        self.store = store
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
        do {
            try store.forgetEverything()
            status = MemoryWords.forgotten
            forgottenCount += 1
        } catch {
            status = MemoryWords.couldNotForget
        }
        refresh()
    }

    private func report(_ decision: @autoclosure () throws -> MemoryStore.Decision, onSaved: () -> Void) {
        do {
            switch try decision() {
            case .saved: status = MemoryWords.saved; savedCount += 1; onSaved()
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
