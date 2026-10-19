import Foundation
import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI

/// Getting the on-device model, as the memory screen shows it.
///
/// The download starts only from `download()`, which only the button calls:
/// never at launch and never on its own. When it ends ready, the app's one
/// `OnDeviceChat` moves to the model, so the next reply in any chat comes
/// from it.
@MainActor
public final class OnDeviceModelSetup: ObservableObject {
    @Published public private(set) var state: ModelDownloadState
    public var pin: PinnedModel { installer.pin }
    private let installer: ModelInstaller
    private let chat: OnDeviceChat
    private let availableMemory: @Sendable () -> UInt64
    private var running: Task<Void, Never>?
    /// The folder the chat could not load, until the person repairs it.
    private var failedFolder: URL?

    /// Starts from what `chat` answers with now, which `OnDeviceModel.client`
    /// worked out from the same folders.
    public init(installer: ModelInstaller, chat: OnDeviceChat,
                availableMemory: @escaping @Sendable () -> UInt64 = { OnDeviceModel.availableMemory() }) {
        self.installer = installer
        self.chat = chat
        self.availableMemory = availableMemory
        state = Self.state(of: chat.active)
        // A model that fails to load, found on the first reply, shows here.
        chat.onLoadFailure { [weak self] folder in
            Task { @MainActor in self?.couldNotLoad(folder) }
        }
        // What a download cut short by the app closing left behind.
        Task { await installer.removeLeftovers() }
    }

    /// The app's one model client and its download, both reading the
    /// folder in `Application Support/<product name>/Models`. The model
    /// downloaded there is used without anything else set; a developer's
    /// `OnDeviceModel.environmentKey` or `defaultsKey` still comes first.
    /// Nothing is fetched here.
    public static func forApp(
        brand: Brand,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        folders: ModelFolders? = nil,
        availableMemory: @escaping @Sendable () -> UInt64 = { OnDeviceModel.availableMemory() }
    ) -> (model: OnDeviceChat, setup: OnDeviceModelSetup?) {
        let folders = folders ?? (try? ModelFolders.onDevice(appFolder: brand.name))
        let model = OnDeviceModel.client(environment: environment, defaults: defaults, folders: folders,
                                         availableMemory: availableMemory())
        let setup = folders.map {
            OnDeviceModelSetup(installer: .overNetwork(folders: $0), chat: model, availableMemory: availableMemory)
        }
        return (model, setup)
    }

    static func state(of model: any ModelClient) -> ModelDownloadState {
        if let model = model as? MLXChatModel { return .ready(model.folder) }
        switch OnDeviceModel.notReady(of: model) {
        case .incomplete?: return .failed(.incomplete)
        case .needsMoreMemory?: return .failed(.needsMoreMemory)
        case .couldNotLoad?: return .failed(.couldNotLoad)
        case .notDownloaded?, nil: return .notDownloaded
        }
    }

    /// The chat found `folder` would not load and went back to the placeholder.
    private func couldNotLoad(_ folder: URL) {
        guard running == nil, !state.isUnderWay else { return }
        failedFolder = folder
        state = .failed(.couldNotLoad)
    }

    /// Removes the folder that would not load, when it is the downloaded
    /// one, and downloads the model again. A developer's own folder is
    /// never removed.
    public func repair() {
        guard running == nil, state == .failed(.couldNotLoad) else { return }
        let installer = installer
        let removes = failedFolder.map { Self.same($0, installer.folders.ready(for: pin)) } ?? false
        failedFolder = nil
        state = .downloading(received: 0, total: pin.totalBytes)
        start { if removes { await installer.removeReady() } }
    }

    private static func same(_ one: URL, _ other: URL) -> Bool {
        one.resolvingSymlinksInPath().standardizedFileURL.path
            == other.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The person asked for the model. Does nothing while one is coming,
    /// once it is ready, or where it can't fit.
    public func download() {
        guard running == nil, !state.isReady else { return }
        if case .failed(let problem) = state, !problem.canTryAgain { return }
        if state == .failed(.couldNotLoad) { return repair() }
        state = .downloading(received: 0, total: pin.totalBytes)
        start {}
    }

    /// Runs `first`, then the install, and takes where it ends.
    private func start(after first: @escaping @Sendable () async -> Void) {
        let installer = installer
        let progress = Progress(total: pin.totalBytes) { [weak self] step in
            Task { @MainActor in self?.heard(step) }
        }
        running = Task { [weak self] in
            await first()
            let end = await installer.install(report: { progress.send($0) })
            self?.finish(end)
        }
    }

    /// Stops the download. What came so far is removed.
    public func stop() {
        running?.cancel()
    }

    /// The task underway, so tests can wait for it.
    var underway: Task<Void, Never>? { running }

    private func heard(_ step: ModelDownloadState) {
        // A step that comes in after the end is old news.
        guard running != nil, state.isUnderWay else { return }
        state = step
    }

    func finish(_ end: ModelDownloadState) {
        running = nil
        guard case .ready(let folder) = end else {
            state = end
            return
        }
        let kind = OnDeviceModel.kind(downloaded: folder, pin: pin, availableMemory: availableMemory())
        let model = OnDeviceModel.model(for: kind)
        chat.use(model)
        state = Self.state(of: model)
    }
}

/// Passes each step on, but a download's progress only about every half a
/// percent, so the screen isn't redrawn for every packet.
private final class Progress: @unchecked Sendable {
    private let total: Int64
    private let forward: @Sendable (ModelDownloadState) -> Void
    private let lock = NSLock()
    private var last: Int64 = -1

    init(total: Int64, forward: @escaping @Sendable (ModelDownloadState) -> Void) {
        self.total = total
        self.forward = forward
    }

    func send(_ step: ModelDownloadState) {
        if case .downloading(let received, _) = step {
            lock.lock()
            let step = max(total / 200, 1)
            let due = last < 0 || received - last >= step || received >= total
            if due { last = received }
            lock.unlock()
            guard due else { return }
        }
        forward(step)
    }
}

extension EnvironmentValues {
    /// The app's model download, for the memory screen. Nil, as in tests
    /// and screenshots, shows nothing.
    @Entry public var onDeviceModelSetup: OnDeviceModelSetup?
}

/// The on-device model's row: where it is, and the one button for what
/// comes next.
struct OnDeviceModelRow: View {
    @ObservedObject var setup: OnDeviceModelSetup
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OnDeviceModelWords.title)
                .font(.body.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            Text(Self.detail(for: setup.state, pin: setup.pin))
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("modelDetail")
            switch setup.state {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .tint(Theme.accentText)
                    .accessibilityHidden(true)
                Button(OnDeviceModelWords.stopTitle) { setup.stop() }
                    .buttonStyle(SoftButtonStyle(neutral: true))
                    .accessibilityIdentifier("stopModelDownload")
            case .verifying:
                ProgressView(value: 1)
                    .tint(Theme.accentText)
                    .accessibilityHidden(true)
            case .notDownloaded:
                Button(OnDeviceModelWords.downloadTitle(bytes: setup.pin.totalBytes)) { setup.download() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("downloadModel")
            case .failed(.couldNotLoad):
                Button(OnDeviceModelWords.downloadAgainTitle) { setup.repair() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("downloadModel")
            case .failed(let problem) where problem.canTryAgain:
                Button(OnDeviceModelWords.tryAgainTitle) { setup.download() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("downloadModel")
            case .failed, .ready:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
        // Each new step once, never each tick of progress.
        .onChange(of: Self.phase(of: setup.state)) { _, _ in
            AccessibilityNotification.Announcement(Self.detail(for: setup.state, pin: setup.pin)).post()
        }
    }

    static func detail(for state: ModelDownloadState, pin: PinnedModel) -> String {
        switch state {
        case .notDownloaded: OnDeviceModelWords.notDownloadedDetail
        case .downloading(let received, let total): OnDeviceModelWords.downloading(received: received, total: total)
        case .verifying: OnDeviceModelWords.verifying
        case .ready: OnDeviceModelWords.ready
        case .failed(.couldNotFetch): OnDeviceModelWords.couldNotFetch
        case .failed(.didNotMatch): OnDeviceModelWords.didNotMatch
        case .failed(.noRoom): OnDeviceModelWords.noRoom(bytes: pin.totalBytes)
        case .failed(.couldNotSave): OnDeviceModelWords.couldNotSave
        case .failed(.incomplete): OnDeviceModelWords.incomplete
        case .failed(.needsMoreMemory): OnDeviceModelWords.needsMoreMemory
        case .failed(.couldNotLoad): OnDeviceModelWords.couldNotLoad
        }
    }

    /// The state without its progress, so a change means a new step.
    static func phase(of state: ModelDownloadState) -> String {
        switch state {
        case .downloading: "downloading"
        case .verifying: "verifying"
        case .notDownloaded: "notDownloaded"
        case .ready: "ready"
        case .failed(let problem): "failed \(problem)"
        }
    }
}
#endif
