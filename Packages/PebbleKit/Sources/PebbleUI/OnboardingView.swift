import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The guided first run: hello, a name, a look, then ideas to start with.
public struct OnboardingView: View {
    public enum Page: Int, CaseIterable, Sendable {
        case hello, name, look, proactivity, ideas
    }

    @StateObject private var model: OnboardingModel
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True only when the model runs on this device, so the hello may
    /// promise that words stay here.
    private let onDevice: Bool

    public init(
        brand: Brand,
        names: any AgentNameStoring,
        store: any OnboardingStoring,
        looks: UserDefaults = .standard,
        onDevice: Bool = false,
        startAt page: Page = .hello,
        draftName: String = "",
        onFinish: @escaping @MainActor (_ firstMessage: String?) -> Void
    ) {
        self.onDevice = onDevice
        _model = StateObject(wrappedValue: OnboardingModel(
            brand: brand, names: names, store: store, looks: looks,
            page: page, draftName: draftName, onFinish: onFinish
        ))
    }

    public var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                progress
                    .padding(.top, 12)
                Spacer(minLength: 12)
                CharacterView(look: model.look, size: model.page == .hello ? 132 : 96, isCheerful: model.page == .ideas)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.75), value: model.page)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.look)
                content
                    .id(model.page)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                Spacer(minLength: 12)
            }
            .padding(.horizontal, Theme.gutter)
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85), value: model.page)
    }

    private var progress: some View {
        let pages = model.visiblePages
        let index = pages.firstIndex(of: model.page) ?? 0
        return HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? Theme.accent : Theme.hairline(scheme))
                    .frame(width: i == index ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(FirstRunWords.step(index + 1, of: pages.count))
    }

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .hello: hello
        case .name: naming
        case .look: lookPicker
        case .proactivity: proactivity
        case .ideas: ideas
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !detail.isEmpty {
                Text(detail)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 20)
    }

    private var hello: some View {
        VStack(spacing: 28) {
            heading(FirstRunWords.hello, FirstRunWords.helloDetail(onDevice: onDevice))
            Button(FirstRunWords.beginTitle) { model.advance() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 12)
        }
    }

    private var naming: some View {
        VStack(spacing: 20) {
            heading(FirstRunWords.nameQuestion, FirstRunWords.nameDetail)
            TextField(FirstConversation.namePlaceholder, text: $model.draftName)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
                .focused($nameFocused)
                .submitLabel(.continue)
                .onSubmit { model.commitName() }
                .accessibilityLabel(FirstRunWords.nameQuestion)
            if let hint = model.hint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentText)
                    .transition(.opacity)
            }
            Button(OnboardingWords.continueTitle) { model.commitName() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(OnboardingWords.skipTitle) { model.skipName() }
                .buttonStyle(QuietButtonStyle())
        }
    }

    private var lookPicker: some View {
        VStack(spacing: 20) {
            heading(FirstRunWords.lookQuestion, FirstRunWords.lookDetail)
            HStack(spacing: 12) {
                ForEach(AgentLook.allCases, id: \.self) { look in
                    Button { model.look = look } label: {
                        VStack(spacing: 6) {
                            CharacterView(look: look, size: 44)
                                .frame(width: 64, height: 64)
                            Text(look.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(model.look == look ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.secondaryText))
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                                .fill(model.look == look ? Theme.card(scheme) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                                .stroke(model.look == look ? Theme.accent : .clear, lineWidth: 2)
                        )
                        .pointerHover()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(look.title)
                    .accessibilityAddTraits(model.look == look ? .isSelected : [])
                }
            }
            Button(OnboardingWords.continueTitle) { model.advance() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    /// Shown only when more than one choice is honored.
    private var proactivity: some View {
        VStack(spacing: 14) {
            heading(OnboardingWords.proactivityQuestion, "")
            ForEach(Proactivity.offered, id: \.self) { choice in
                Button { model.choose(choice) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.title).font(.headline)
                        Text(choice.detail).font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    .pointerHover(in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ideas: some View {
        VStack(spacing: 16) {
            heading(FirstRunWords.greeting(named: model.displayName), FirstRunWords.ideasDetail)
            VStack(spacing: 10) {
                ForEach(Array(model.starters.enumerated()), id: \.element.id) { index, job in
                    IdeaCardButton(job: job, index: index) { model.pick(job) }
                }
            }
            Button(FirstRunWords.justChatTitle) { model.finishWithoutIdea() }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

/// One starter idea, styled as a tappable card.
struct IdeaCardButton: View {
    let job: StarterJob
    let index: Int
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private var symbol: String {
        switch job.id {
        case "morning": "sun.horizon"
        case "talk": "bubble.left.and.bubble.right"
        case "remember": "bookmark"
        default: "sparkles"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accentSymbol)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(Theme.accentWash), in: Circle())
                Text(job.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(14)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
            .pointerHover(in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(job.title)
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 12)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(reduceMotion ? 0 : 0.08 * Double(index))) {
                shown = true
            }
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    let brand: Brand
    private let names: any AgentNameStoring
    private let store: any OnboardingStoring
    private let looks: UserDefaults
    private let onFinish: @MainActor (String?) -> Void
    private var flow = OnboardingFlow()

    @Published var page: OnboardingView.Page
    @Published var draftName: String
    @Published var look: AgentLook
    @Published private(set) var hint: String?

    init(
        brand: Brand, names: any AgentNameStoring, store: any OnboardingStoring, looks: UserDefaults,
        page: OnboardingView.Page, draftName: String, onFinish: @escaping @MainActor (String?) -> Void
    ) {
        self.brand = brand
        self.names = names
        self.store = store
        self.looks = looks
        self.page = page
        self.draftName = draftName
        self.look = AgentLook.load(from: looks)
        self.onFinish = onFinish
        if page.rawValue > OnboardingView.Page.name.rawValue {
            if draftName.isEmpty { flow.skip() } else { flow.chooseName(draftName) }
        }
    }

    var visiblePages: [OnboardingView.Page] {
        OnboardingView.Page.allCases.filter { $0 != .proactivity || Proactivity.offered.count > 1 }
    }

    var displayName: String {
        flow.name?.text ?? AgentProfile(brand: brand, stored: names.loadDisplayName()).displayName.text
    }

    var starters: [StarterJob] { flow.starters }

    func advance() {
        let pages = visiblePages
        guard let i = pages.firstIndex(of: page), i + 1 < pages.count else { return }
        if page == .look { look.save(to: looks) }
        page = pages[i + 1]
    }

    func commitName() {
        // The name is saved with everything else when the first run finishes,
        // so quitting halfway brings the whole first run back.
        if flow.chooseName(draftName) {
            hint = nil
            advance()
        } else {
            hint = flow.hint
        }
    }

    func skipName() {
        hint = nil
        flow.skip()
        advance()
    }

    func choose(_ choice: Proactivity) {
        flow.chooseProactivity(choice)
        advance()
    }

    func pick(_ job: StarterJob) {
        moveFlowToStarters()
        let line = flow.pickStarter(job.id)
        finish(with: line)
    }

    func finishWithoutIdea() {
        moveFlowToStarters()
        flow.skip()
        finish(with: nil)
    }

    private func moveFlowToStarters() {
        while flow.step < .starters { flow.skip() }
    }

    private func finish(with line: String?) {
        look.save(to: looks)
        flow.save(to: store, names: names)
        onFinish(line)
    }
}

#Preview {
    OnboardingView(brand: Brand(name: "Preview"), names: InMemoryAgentNameStore(), store: InMemoryOnboardingStore()) { _ in }
}
#endif
