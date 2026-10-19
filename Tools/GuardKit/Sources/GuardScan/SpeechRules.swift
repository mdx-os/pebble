import SwiftSyntax

/// Speech is heard on the device only, and nothing heard is kept.
///
/// Every recognition request is made as a named value in one block, and
/// that same block sets its `requiresOnDeviceRecognition` to `true` before
/// anything else touches it, so the system never sends speech to a server,
/// not even as a fallback. Nothing may set it to anything else. The name is
/// a `let` and never given another request, and in the adapter nothing is
/// made with a `.init(...)` whose type the guard can't read. The recognizer lives in one file,
/// `PebbleVoice/DeviceSpeech.swift`, so there is one place to read. The
/// voice files name nothing that writes to disk or a log, so no audio and
/// no words are kept. A name in backticks is the same name.
public enum SpeechGate {
    /// The one file that may name the Speech framework, under PebbleKit's Sources.
    public static let adapterFile = "PebbleVoice/DeviceSpeech.swift"

    /// The files that handle what is heard: the adapter's layer, the
    /// capture and its button.
    public static let voiceFolders = ["PebbleVoice/"]
    public static let voiceFiles: Set<String> = ["PebbleCore/VoiceCapture.swift", "PebbleUI/TalkButton.swift"]

    /// The requests that can be sent to a recognizer.
    public static let requestTypes: Set<String> = [
        "SFSpeechAudioBufferRecognitionRequest", "SFSpeechURLRecognitionRequest", "SFSpeechRecognitionRequest",
    ]

    /// Speech framework names besides the `SFSpeech` ones, which are all caught.
    public static let speechNames: Set<String> = ["SpeechAnalyzer", "SpeechTranscriber", "DictationTranscriber",
                                                  "SpeechDetector", "AssetInventory"]

    /// What would keep audio or words: files, settings, logs and caches.
    public static let keepingNames: Set<String> = [
        "FileManager", "FileHandle", "UserDefaults", "NSUbiquitousKeyValueStore", "Logger", "OSLog", "os_log",
        "NSLog", "print", "debugPrint", "dump", "AVAudioFile", "AVAudioRecorder", "URLCache", "NSCache",
        "createFile", "ModelContainer", "Keychain", "SecItemAdd",
    ]

    static let flag = "requiresOnDeviceRecognition"

    public static let rules: [Rule] = [
        Rule("speech.requestNotOnDevice", requestNotOnDevice),
        Rule("speech.requestUnresolved", requestUnresolved),
        Rule("speech.requestReassigned", requestReassigned),
        Rule("speech.usedBeforeOnDevice", usedBeforeOnDevice),
        Rule("speech.onDeviceTurnedOff", onDeviceTurnedOff),
        Rule("speech.outsideAdapter", outsideAdapter),
        Rule("speech.keepsWords", keepsWords),
    ]

    public static func problems(in source: SyntaxSource, file: String) -> [Finding] {
        rules.flatMap { $0.check(source, file) }.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    public static func isVoiceFile(_ file: String) -> Bool {
        voiceFiles.contains(file) || voiceFolders.contains { file.hasPrefix($0) }
    }

    // MARK: Requests

    /// A request made without `requiresOnDeviceRecognition = true` set on it
    /// in the same block, or made where it can't be named, as a function
    /// reference or straight into a call.
    @Sendable static func requestNotOnDevice(_ source: SyntaxSource, _ file: String) -> [Finding] {
        var found: [Finding] = []
        for call in source.nodes(FunctionCallExprSyntax.self) where makesRequest(call) {
            guard let name = boundName(of: call), let scope = SyntaxSource.enclosingBraces(of: call),
                  setsOnDevice(name, in: scope) else {
                found.append(Finding("speech.requestNotOnDevice", at: call, in: source,
                                     "make a recognition request as `let request = ...` and set "
                                         + "`request.\(flag) = true` in the same block, so speech is heard on "
                                         + "the device only"))
                continue
            }
        }
        // `SFSpeechAudioBufferRecognitionRequest.init` passed along, made out of sight.
        for member in source.nodes(MemberAccessExprSyntax.self) where SyntaxSource.name(member.declName.baseName) == "init" {
            guard let base = member.base, requestTypes.contains(lastName(base) ?? ""),
                  member.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != ExprSyntax(member).id else {
                continue
            }
            found.append(Finding("speech.requestNotOnDevice", at: member, in: source,
                                 "a recognition request is made only by a call bound to a name"))
        }
        return found
    }

    /// True when `call` makes a request: `T(...)`, `T.init(...)`,
    /// `Speech.T(...)`, or `.init(...)` given a request type.
    static func makesRequest(_ call: FunctionCallExprSyntax) -> Bool {
        var callee = call.calledExpression
        if let member = callee.as(MemberAccessExprSyntax.self), SyntaxSource.name(member.declName.baseName) == "init" {
            guard let base = member.base else {
                // `.init(...)`: made as whatever type it is given.
                return declaredType(of: call).map(requestTypes.contains) ?? false
            }
            callee = base
        }
        return lastName(callee).map(requestTypes.contains) ?? false
    }

    /// The type a call's binding is declared with: `T` in `let r: T = .init()`.
    static func declaredType(of call: FunctionCallExprSyntax) -> String? {
        guard let binding = call.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
              let type = binding.typeAnnotation?.type else { return nil }
        return Array(type.tokens(viewMode: .sourceAccurate)).last { $0.identifier != nil }.map(SyntaxSource.name)
    }

    /// The last name in `a`, `A.b` or `A.B.c`.
    static func lastName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return SyntaxSource.name(reference.baseName) }
        if let member = expression.as(MemberAccessExprSyntax.self) { return SyntaxSource.name(member.declName.baseName) }
        return nil
    }

    /// The name a call is bound to, as in `let request = T()`.
    static func boundName(of call: FunctionCallExprSyntax) -> String? {
        guard let binding = call.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
        return SyntaxSource.name(pattern.identifier)
    }

    /// True when `scope` itself, not a block inside it, says
    /// `name.requiresOnDeviceRecognition = true`.
    static func setsOnDevice(_ name: String, in scope: Syntax) -> Bool {
        onDeviceSetting(name, in: scope) != nil
    }

    /// The first `name.requiresOnDeviceRecognition = true` in `scope` itself.
    static func onDeviceSetting(_ name: String, in scope: Syntax) -> InfixOperatorExprSyntax? {
        scope.descendants(InfixOperatorExprSyntax.self).first { infix in
            guard infix.operator.is(AssignmentExprSyntax.self),
                  let target = infix.leftOperand.as(MemberAccessExprSyntax.self),
                  SyntaxSource.name(target.declName.baseName) == flag,
                  let base = target.base?.as(DeclReferenceExprSyntax.self), SyntaxSource.name(base.baseName) == name,
                  infix.rightOperand.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.true),
                  SyntaxSource.enclosingBraces(of: infix)?.id == scope.id else { return false }
            return true
        }
    }

    /// The requests made by a call bound to a name, with the name and the
    /// block they are made in.
    static func boundRequests(in source: SyntaxSource)
        -> [(call: FunctionCallExprSyntax, name: String, scope: Syntax)] {
        source.nodes(FunctionCallExprSyntax.self).compactMap { call in
            guard makesRequest(call), let name = boundName(of: call),
                  let scope = SyntaxSource.enclosingBraces(of: call) else { return nil }
            return (call, name, scope)
        }
    }

    /// In the adapter, something made with `.init(...)` whose type the
    /// guard can't read, so it could be a request made without the flag,
    /// as in `request = .init()`; or a request type under another name,
    /// through a `typealias`.
    @Sendable static func requestUnresolved(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file == adapterFile else { return [] }
        let made = source.nodes(FunctionCallExprSyntax.self).filter { call in
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.base == nil, SyntaxSource.name(member.declName.baseName) == "init" else { return false }
            return declaredType(of: call) == nil
        }.map { call in
            Finding("speech.requestUnresolved", at: call, in: source,
                    "in the adapter, `.init(...)` is only for `let name: Type = .init(...)`, so a recognition "
                        + "request is never made out of sight of its on-device setting")
        }
        let aliases = source.nodes(TypeAliasDeclSyntax.self).filter { alias in
            alias.initializer.value.tokens(viewMode: .sourceAccurate).contains { token in
                token.identifier != nil && requestTypes.contains(SyntaxSource.name(token))
            }
        }.map { alias in
            Finding("speech.requestUnresolved", at: alias, in: source,
                    "a recognition request is named by its own type, never through a typealias")
        }
        return made + aliases
    }

    /// A request bound with `var`, or its name given something else after,
    /// so the request that is used may not be the one set to stay on the device.
    @Sendable static func requestReassigned(_ source: SyntaxSource, _ file: String) -> [Finding] {
        var found: [Finding] = []
        for (call, name, scope) in boundRequests(in: source) {
            if let decl = call.parent?.parent?.parent?.parent?.as(VariableDeclSyntax.self),
               decl.bindingSpecifier.tokenKind == .keyword(.var) {
                found.append(Finding("speech.requestReassigned", at: decl, in: source,
                                     "a recognition request is bound with `let`, so it is never swapped for "
                                         + "another"))
            }
            for infix in scope.descendants(InfixOperatorExprSyntax.self) where infix.operator.is(AssignmentExprSyntax.self) {
                guard let target = infix.leftOperand.as(DeclReferenceExprSyntax.self),
                      SyntaxSource.name(target.baseName) == name,
                      infix.position > call.endPosition else { continue }
                found.append(Finding("speech.requestReassigned", at: infix, in: source,
                                     "`\(name)` is never given another request once it is made"))
            }
        }
        return found
    }

    /// A request used before `requiresOnDeviceRecognition = true` is set on
    /// it: the setting comes right after the request is made.
    @Sendable static func usedBeforeOnDevice(_ source: SyntaxSource, _ file: String) -> [Finding] {
        var found: [Finding] = []
        for (call, name, scope) in boundRequests(in: source) {
            guard let setting = onDeviceSetting(name, in: scope) else { continue }
            for reference in scope.descendants(DeclReferenceExprSyntax.self)
            where SyntaxSource.name(reference.baseName) == name
                && reference.position > call.endPosition && reference.position < setting.position {
                // `other.request` names something else.
                if let member = reference.parent?.as(MemberAccessExprSyntax.self),
                   member.declName.id == reference.id { continue }
                found.append(Finding("speech.usedBeforeOnDevice", at: reference, in: source,
                                     "set `\(name).\(flag) = true` before `\(name)` is used"))
            }
        }
        return found
    }

    /// `requiresOnDeviceRecognition` set to anything but `true`, toggled,
    /// written through a key path, or named in a string for key-value coding.
    @Sendable static func onDeviceTurnedOff(_ source: SyntaxSource, _ file: String) -> [Finding] {
        var found: [Finding] = []
        for token in source.tokens where token.identifier != nil && SyntaxSource.name(token) == flag {
            // `request.flag`, or `flag` alone, as inside an extension.
            guard let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { continue }
            let written: ExprSyntax = token.parent?.parent?.as(MemberAccessExprSyntax.self).map(ExprSyntax.init)
                ?? ExprSyntax(reference)
            if let infix = written.parent?.as(InfixOperatorExprSyntax.self), infix.leftOperand.id == written.id {
                if infix.operator.is(AssignmentExprSyntax.self),
                   infix.rightOperand.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.true) {
                    continue
                }
                found.append(Finding("speech.onDeviceTurnedOff", at: token, in: source,
                                     "\(flag) is only ever set to true"))
                continue
            }
            if let outer = written.parent?.as(MemberAccessExprSyntax.self), outer.base?.id == written.id,
               SyntaxSource.name(outer.declName.baseName) == "toggle" {
                found.append(Finding("speech.onDeviceTurnedOff", at: token, in: source, "\(flag) is never toggled"))
                continue
            }
            if isInKeyPath(token) {
                found.append(Finding("speech.onDeviceTurnedOff", at: token, in: source,
                                     "\(flag) is set by name, to true, never through a key path"))
            }
        }
        for literal in source.literals where literal.value == flag {
            found.append(Finding("speech.onDeviceTurnedOff", at: literal.node, in: source,
                                 "\(flag) is set by name, to true, never by a string"))
        }
        return found
    }

    static func isInKeyPath(_ token: TokenSyntax) -> Bool {
        var current = token.parent
        while let node = current {
            if node.is(KeyPathExprSyntax.self) { return true }
            current = node.parent
        }
        return false
    }

    // MARK: Where

    /// The Speech framework named, or imported, outside the adapter.
    @Sendable static func outsideAdapter(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard file != adapterFile else { return [] }
        let names = source.tokens.filter { token in
            guard token.identifier != nil else { return false }
            let name = SyntaxSource.name(token)
            return name.hasPrefix("SFSpeech") || speechNames.contains(name)
        }.map { token in
            Finding("speech.outsideAdapter", at: token, in: source,
                    "\(SyntaxSource.name(token)) belongs only in \(adapterFile), where every request is heard on "
                        + "the device")
        }
        let imports = source.nodes(ImportDeclSyntax.self).filter { decl in
            decl.path.first.map { SyntaxSource.name($0.name) } == "Speech"
        }.map { decl in
            Finding("speech.outsideAdapter", at: decl, in: source, "import Speech belongs only in \(adapterFile)")
        }
        return names + imports
    }

    /// In the voice files, anything that could keep audio or words: a file,
    /// a setting, a log or a cache, or a `write(to:)`.
    @Sendable static func keepsWords(_ source: SyntaxSource, _ file: String) -> [Finding] {
        guard isVoiceFile(file) else { return [] }
        let names = source.tokens.filter { token in
            token.identifier != nil && keepingNames.contains(SyntaxSource.name(token))
                && !PlatformGate.inCondition(token)
        }.map { token in
            Finding("speech.keepsWords", at: token, in: source,
                    "nothing heard is kept: \(SyntaxSource.name(token)) has no place in a voice file")
        }
        let writes = source.calls(named: ["write"]).filter { call in
            let label = call.arguments.first?.label.map(SyntaxSource.name)
            return label == "to" || label == "toFile" || label == "toURL"
        }.map { call in
            Finding("speech.keepsWords", at: call, in: source, "nothing heard is written to a file")
        }
        let logging = source.nodes(ImportDeclSyntax.self).filter { decl in
            ["os", "OSLog"].contains(decl.path.first.map { SyntaxSource.name($0.name) } ?? "")
        }.map { decl in
            Finding("speech.keepsWords", at: decl, in: source, "nothing heard is logged")
        }
        return names + writes + logging
    }
}
