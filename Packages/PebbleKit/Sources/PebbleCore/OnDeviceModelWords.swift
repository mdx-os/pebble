import Foundation

/// Why replies can't come from the on-device model yet.
public enum OnDeviceModelNotReady: Sendable, Equatable, CaseIterable {
    /// Nothing has been downloaded.
    case notDownloaded
    /// A model folder is there, but files are missing or the wrong size.
    case incomplete
    /// The weights are more than this device can hold in memory.
    case needsMoreMemory
    /// The files are all there, but the model couldn't be opened from them.
    case couldNotLoad
}

/// Words for getting the on-device model, on the memory screen and in the
/// chat while it isn't ready. None of them promise where words go: the
/// download carries nothing the person wrote, and that is all they say.
public enum OnDeviceModelWords {
    public static let title = "On-device model"

    /// "about 2.3 GB", in decimal gigabytes, as the system shows sizes.
    public static func size(_ bytes: Int64) -> String {
        let tenths = (Double(bytes) / 100_000_000).rounded()
        return String(format: "%.1f GB", tenths / 10)
    }

    /// The button. The download starts only from here.
    public static func downloadTitle(bytes: Int64) -> String {
        downloadTitleStart + size(bytes)
    }

    static let downloadTitleStart = "Download on-device model, about "

    public static let notDownloadedDetail = "I answer best with a small open model that runs right here. It's a one-time download. Only the model's own files are fetched, never anything you wrote."

    public static func downloading(received: Int64, total: Int64) -> String {
        "Downloading. \(amount(received, of: total)) of \(size(total))."
    }

    public static let stopTitle = "Stop download"
    public static let verifying = "Checking the files."
    public static let ready = "Ready. The model is downloaded, and I use it to answer."
    public static let tryAgainTitle = "Try again"

    public static let couldNotFetch = "Sorry, the download didn't finish. Nothing half done was kept."
    public static let didNotMatch = "Sorry, the files that came weren't the ones I expected, so I didn't keep them."
    public static func noRoom(bytes: Int64) -> String {
        "There isn't enough free space for the model. It needs about \(size(bytes))."
    }
    public static let couldNotSave = "Sorry, I couldn't save the model just now."
    public static let incomplete = "Some of the model's files are missing, so I'm not using them."
    public static let needsMoreMemory = "There isn't enough memory free here for the model, so I can't use it."
    public static let couldNotLoad = "Sorry, the model's files are here but they didn't open, so I'm not using them. Download it again to fix that."
    public static let downloadAgainTitle = "Download again"

    /// The chat's line when the latest message is more than the model can
    /// read at once. The words go back to the composer.
    public static let tooLong = "That's too long for me to read at once. What you wrote is still here, so you can send a shorter part of it."

    /// The chat's line when the app left the screen before the reply was
    /// done, on iPhone and iPad. The message stays in the chat and its words
    /// go back to the composer, so sending them again asks again.
    public static let interrupted = "Sorry, I stopped that reply when you left the app. What you wrote is still here, so you can send it again."

    /// What the chat says instead of pretending to answer. Each names the
    /// memory screen as `MemoryWords.title` says it; the tests hold them
    /// to that.
    public static func notReadyReply(_ reason: OnDeviceModelNotReady) -> String {
        switch reason {
        case .notDownloaded:
            "Sorry, I can't really answer that yet. My on-device model isn't downloaded. To get it, open What I remember and choose Download on-device model. Until then I can plan a morning, say a detail back, or help you talk something through."
        case .incomplete:
            "Sorry, I can't really answer that yet. Some of my on-device model's files are missing. Open What I remember to download it again."
        case .needsMoreMemory:
            "Sorry, I can't really answer that here. There isn't enough memory free for my on-device model."
        case .couldNotLoad:
            "Sorry, I can't really answer that yet. My on-device model's files didn't open. Open What I remember to download it again."
        }
    }

    /// Every fixed line, for the voice checks.
    public static var all: [String] {
        [title, downloadTitle(bytes: 2_274_455_727), notDownloadedDetail,
         downloading(received: 1_200_000_000, total: 2_274_455_727), stopTitle, verifying, ready, tryAgainTitle,
         couldNotFetch, didNotMatch, noRoom(bytes: 2_274_455_727), couldNotSave, incomplete, needsMoreMemory,
         couldNotLoad, downloadAgainTitle, tooLong, interrupted]
            + OnDeviceModelNotReady.allCases.map(notReadyReply)
    }

    /// The amount so far, in the total's unit, so "1.2 of 2.3 GB" reads as one number.
    private static func amount(_ received: Int64, of total: Int64) -> String {
        let tenths = (Double(min(max(received, 0), total)) / 100_000_000).rounded(.down)
        return String(format: "%.1f", tenths / 10)
    }
}
