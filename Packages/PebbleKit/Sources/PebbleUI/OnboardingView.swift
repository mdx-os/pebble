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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.holdsStill) private var holdsStill
    /// Reduce Motion, or a screenshot that needs the screen to settle.
    private var reduceMotion: Bool { systemReduceMotion || holdsStill }
    /// True only when the model runs on this device, so the hello may
    /// promise that words stay here.
    private let place: PrivacyPlace

    public init(
        brand: Brand,
        names: any AgentNameStoring,
        store: any OnboardingStoring,
        looks: UserDefaults = .standard,
        place: PrivacyPlace = .mayLeaveDevice,
        startAt page: Page = .hello,
        draftName: String = "",
        onFinish: @escaping @MainActor (_ firstMessage: String?) -> Void
    ) {
        self.place = place
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
                    .padding(.top, Theme.Space.s)
                Spacer(minLength: Theme.Space.s)
                CharacterView(look: model.look, size: model.page == .hello ? 132 : 96, isCheerful: model.page == .ideas)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.75), value: model.page)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.look)
                content
                    .id(model.page)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                Spacer(minLength: Theme.Space.s)
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
        return HStack(spacing: Theme.Space.xs) {
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
        VStack(spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.TypeScale.displayLarge)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Theme.Space.l)
    }

    private var hello: some View {
        VStack(spacing: Theme.Space.xxl) {
            heading(FirstRunWords.hello, FirstRunWords.helloDetail(place))
            Button(FirstRunWords.beginTitle) { model.advance() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, Theme.Space.s)
        }
    }

    private var naming: some View {
        VStack(spacing: Theme.Space.l) {
            heading(FirstRunWords.nameQuestion, FirstRunWords.nameDetail)
            TextField(FirstConversation.namePlaceholder, text: $model.draftName)
                .font(Theme.TypeScale.displayTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .padding(.vertical, Theme.Space.m)
                .padding(.horizontal, Theme.Space.l)
                .cardSurface()
                .focused($nameFocused)
                .submitLabel(.continue)
                .onSubmit { model.commitName() }
                .accessibilityLabel(FirstRunWords.nameQuestion)
            if let hint = model.hint {
                Text(hint)
                    .font(Theme.TypeScale.subheadline)
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
        VStack(spacing: Theme.Space.l) {
            heading(FirstRunWords.lookQuestion, FirstRunWords.lookDetail)
            HStack(spacing: Theme.Space.s) {
                ForEach(AgentLook.allCases, id: \.self) { look in
                    Button { model.look = look } label: {
                        VStack(spacing: Theme.Space.xs) {
                            CharacterView(look: look, size: 44)
                                .frame(width: 64, height: 64)
                            Text(look.title)
                                .font(Theme.TypeScale.caption.weight(.medium))
                                .foregroundStyle(model.look == look ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.secondaryText))
                        }
                        .padding(.vertical, Theme.Space.s)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(model.look == look ? Theme.card(scheme) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
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
        VStack(spacing: Theme.Space.m) {
            heading(OnboardingWords.proactivityQuestion, "")
            ForEach(Proactivity.offered, id: \.self) { choice in
                Button { model.choose(choice) } label: {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(choice.title).font(Theme.TypeScale.headline)
                        Text(choice.detail).font(Theme.TypeScale.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .pointerHover(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ideas: some View {
        VStack(spacing: Theme.Space.m) {
            heading(FirstRunWords.greeting(named: model.displayName), FirstRunWords.ideasDetail)
            VStack(spacing: Theme.Space.s) {
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.holdsStill) private var holdsStill
    @State private var shown = false
    /// Reduce Motion, or a screenshot that needs the screen to settle.
    private var reduceMotion: Bool { systemReduceMotion || holdsStill }

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
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(Theme.TypeScale.title3)
                    .foregroundStyle(Theme.accentSymbol)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(Theme.accentWash), in: Circle())
                Text(job.title)
                    .font(Theme.TypeScale.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Theme.TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(Theme.Space.m)
            .cardSurface()
            .pointerHover(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
