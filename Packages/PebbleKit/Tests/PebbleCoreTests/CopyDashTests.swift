import Foundation
import PebbleCore
import SourceScan
import Testing

/// docs/VOICE.md: no em dashes and no en dashes anywhere a person reads.
struct CopyDashTests {
    static let dashes: [Character] = ["\u{2014}", "\u{2013}"]

    /// The words people see on each screen.
    static let copy: [String] = [
        FirstRunWords.hello, FirstRunWords.helloDetail(.onDevice), FirstRunWords.helloDetail(),
        FirstRunWords.beginTitle,
        FirstRunWords.nameQuestion, FirstRunWords.nameDetail, FirstRunWords.lookQuestion,
        FirstRunWords.lookDetail, FirstRunWords.ideasDetail, FirstRunWords.justChatTitle,
        FirstRunWords.step(1, of: 4), FirstRunWords.greeting(named: "Pip"),
        OnboardingWords.welcome, OnboardingWords.proactivityQuestion, OnboardingWords.startersHeading,
        OnboardingWords.continueTitle, OnboardingWords.skipTitle,
        FirstConversation.presence(.onDevice), FirstConversation.presence(.mayLeaveDevice),
        FirstConversation.composerPlaceholder, FirstConversation.sendTitle,
        FirstConversation.thinking, FirstConversation.couldNotAnswer, FirstConversation.couldNotAnswerKeptDraft,
        FirstConversation.startersHeading,
        FirstConversation.nameInvitation, FirstConversation.giveNameTitle, FirstConversation.changeNameTitle,
        FirstConversation.namePlaceholder, FirstConversation.confirmNameTitle, FirstConversation.cancelNameTitle,
        FirstConversation.needsAName, FirstConversation.nameTooLong,
        FirstConversation.opening(named: "Pip", place: .onDevice), FirstConversation.opening(named: "Pip"),
        MemoryWords.title, MemoryWords.emptyTitle, MemoryWords.emptyActionTitle,
        MemoryWords.empty(.onDevice), MemoryWords.empty(.mayLeaveDevice),
        MemoryWords.saved(.onDevice), MemoryWords.saved(.mayLeaveDevice),
        MemoryWords.privacyNote(.onDevice), MemoryWords.privacyNote(.mayLeaveDevice),
        MemoryWords.forgetTitle, MemoryWords.forgetEverythingTitle, MemoryWords.forgotten,
        MemoryWords.needsWords, MemoryWords.tooLong, MemoryWords.editTitle, MemoryWords.saveTitle,
        MemoryWords.cancelTitle, MemoryWords.doneTitle, MemoryWords.addPlaceholder, MemoryWords.addTitle,
        MemoryWords.forgetEverythingQuestion, MemoryWords.forgetEverythingDetail(background: true),
        MemoryWords.forgetEverythingDetail(background: false),
        MemoryWords.unreadable, MemoryWords.unavailable, MemoryWords.couldNotOpen, MemoryWords.tryAgainTitle,
        MemoryWords.forgetOneQuestion, MemoryWords.editPlaceholder, MemoryWords.couldNotForget,
        MemoryWords.couldNotForgetNotes, MemoryWords.couldNotSave, MemoryWords.summariesGone,
        MemoryWords.summariesStayed, MemoryWords.forgetSummariesTitle, MemoryWords.forgetSummariesQuestion,
        MemoryWords.forgetSummariesDetail, MemoryWords.couldNotForgetSummariesAlone,
        MemorySource.toldMe.label, MemorySource.fromApp("Calendar").label, MemorySource.inferred.label,
        ConfirmationWords.heading, ConfirmationWords.toLabel, ConfirmationWords.fromLabel,
        ConfirmationWords.whatLabel, ConfirmationWords.whereLabel, ConfirmationWords.priceLabel,
        ConfirmationWords.expired, ConfirmationWords.closeTitle, ConfirmationWords.promise,
        ConfirmationWords.sharedLabel, ConfirmationWords.happensLabel,
        ProposedAction.yesTitle, ProposedAction.noTitle, ProposedAction.declined,
        CareCheck.reply, CareCheck.followUp,
    ] + PrivacyPlaceTests.everyPlace.map(CloudWords.offDetail)
      + FirstConversation.jobs.flatMap { [$0.title, $0.prompt] }
      + Proactivity.allCases.flatMap { [$0.title, $0.detail] }
      + AgentLook.allCases.map(\.title)
      + HomeWords.all
      + FeedWords.all
      + CloudWords.all
      + Redaction.Kind.allCases.flatMap { [$0.mask, $0.counted(1), $0.counted(2)] }
      + TaskWords.all
      + BackgroundWordsTests.all
      + MemoryWords.couldNotForgetSummariesLines
      + ReceiptWords.all
      + NudgeWords.all

    @Test func noScreenWordsUseADash() throws {
        for line in Self.copy + (try DigestWords.all()) {
            #expect(!line.contains(where: Self.dashes.contains), "dash in: \(line)")
        }
    }

    /// Every line a task card can show, from the one list both word tests
    /// read. A line missing here would go unchecked, so a few spot checks.
    @Test func everyTaskLineIsChecked() {
        let all = TaskWords.all
        for line in [TaskWords.youSaidYes, TaskWords.timedOut("x"), TaskWords.couldNotAsk("x"),
                     TaskWords.tookAnotherWay("x"), TaskWords.youSaid("x"), TaskWords.stillWorking,
                     TaskWords.percentDone(40), TaskWords.finishingApproved, TaskWords.mayBeDone("x"),
                     TaskWords.yesNotUsed, TaskWords.forgetTasksDetail, TaskWords.questionTimedOut,
                     TaskWords.tasksForgotten, TaskWords.forgotUnderway(1), TaskWords.forgotUnderway(3),
                     TaskWords.couldNotStart] {
            #expect(all.contains(line), "unchecked: \(line)")
        }
        #expect(Set(TaskState.allCases.map(\.label)).isSubset(of: Set(all)))
    }

    /// The Forget everything lines about the morning summaries come in
    /// through `CloudWords.all` and `MemoryWords`, so they are swept too.
    @Test func theSummaryLinesAreChecked() {
        for line in [CloudWords.forgetEverythingWithSummariesDetail, MemoryWords.summariesGone,
                     MemoryWords.summariesStayed, MemoryWords.forgetEverythingDetail(background: true)]
            + MemoryWords.couldNotForgetSummariesLines + CloudWords.forgotAndCloudOffNotSummariesLines {
            #expect(Self.copy.contains(line), "unchecked: \(line)")
        }
    }

    /// Catches new words too: no source file and not the voice guide.
    @Test func noSourceFileOrTheVoiceGuideUsesADash() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let guide = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/VOICE.md")
        for file in files + [guide] {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(where: Self.dashes.contains), "dash in \(file.lastPathComponent)")
        }
    }

    /// Promises the warmth pass must keep word for word.
    @Test func privacyAndCarePromisesStand() {
        #expect(FirstConversation.opening(named: "Pip", place: .onDevice).contains("so what you tell me stays here"))
        #expect(!FirstConversation.opening(named: "Pip", place: .mayLeaveDevice).contains("stays"))
        // The hello only promises it when the model runs here, like the opening.
        #expect(FirstRunWords.helloDetail(.onDevice).contains("Everything you tell me stays on this device."))
        #expect(!FirstRunWords.helloDetail(.mayLeaveDevice).contains("stays"))
        #expect(!FirstRunWords.helloDetail().contains("stays"))
        #expect(MemoryWords.privacyNote(.onDevice) == "Kept only on this device. Removing a note erases it.")
        #expect(MemoryWords.forgotten == "Gone. I no longer have it.")
        // Forget everything says it stops tasks, and the tasks-only fallback
        // says the notes are left alone.
        for background in [true, false] {
            #expect(MemoryWords.forgetEverythingDetail(background: background).contains("every task"))
            #expect(MemoryWords.forgetEverythingDetail(background: background).contains("stops any task still going"))
        }
        // And it says background work stops too, as `BackgroundRunner.forget`
        // does, only where there is background work to stop.
        #expect(MemoryWords.forgetEverythingDetail(background: true).contains("turns off work while you're away"))
        #expect(!MemoryWords.forgetEverythingDetail(background: false).contains("away"))
        #expect(!MemoryWords.forgetEverythingDetail(background: false).contains("summary"))
        #expect(TaskWords.forgetTasksDetail.contains("stops any task still going"))
        #expect(TaskWords.forgetTasksDetail.contains("Your notes aren't touched"))
        // Forget everything keeps the nudge choice, so every way it is
        // offered says so, and "everything" never misleads.
        for detail in [MemoryWords.forgetEverythingDetail(background: false),
                       MemoryWords.forgetEverythingDetail(background: true), CloudWords.forgetEverythingDetail,
                       CloudWords.forgetEverythingWithSummariesDetail,
                       TaskWords.forgetTasksDetail, CloudWords.forgetTasksAndWordsDetail] {
            #expect(detail.localizedCaseInsensitiveContains("your choice about nudges stays as it is."), "\(detail)")
        }
        #expect(CareCheck.reply.contains("988"))
        #expect(CareCheck.followUp.contains("988"))
        #expect(ConfirmationWords.promise.contains("once, exactly as shown"))
        #expect(ConfirmationWords.expired.contains("so I didn't do it."))
    }

    /// The voice guide quotes the approval buttons; they must match the app.
    @Test func theVoiceGuideQuotesTheRealButtonTitles() throws {
        let guide = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/VOICE.md")
        let text = try String(contentsOf: guide, encoding: .utf8)
        #expect(text.contains("(\"\(ProposedAction.yesTitle)\" and \"\(ProposedAction.noTitle)\""))
        // The name limit is referred to, not copied, so it can't drift.
        #expect(!text.contains("\(AgentName.maxLength) letters"))
    }
}

extension HomeWords {
    /// Every home screen line a person can see or hear, with sample counts
    /// where a line takes one.
    static var all: [String] {
        [chatTitle, newChatTitle, goMenuTitle, shortcutsTitle, sendShortcut, newLineShortcut,
         sendFromAnywhereShortcut, closeShortcut, newChatQuestion, newChatDetail, newChatConfirm, cancelTitle,
         waiting(1), waiting(3)]
        + shortcuts.flatMap { [$0.keys, $0.action] }
    }
}

extension TaskWords {
    /// Every task line a person can see or hear, with sample words where a
    /// line takes some. The one list the dash test and the warmth test read.
    static var all: [String] {
        [workingHeading, workingDetail, runningLabel, stalledLabel, retryingLabel, stoppedLabel, failedLabel,
         stalled, retrying, stuck, waitingForYes, redirected, stopped, interrupted, failed, keptNothing, stillWorking,
         approveTitle, redirectTitle, redirectPlaceholder, redirectSendTitle, redirectCancelTitle, stopTitle,
         tryAgainTitle, dismissTitle, youSaidYes, finishingApproved, yesNotUsed, couldNotStart,
         forgetTasksTitle, forgetTasksQuestion, forgetTasksDetail, questionTimedOut, tasksForgotten,
         forgotUnderway(1), forgotUnderway(2), forgotUnderwayDismissTitle, couldNotEraseTasks, tasksStayed, forgotNotesNotTasks,
         youSaid("x"), tookAnotherWay("x"), declined("x"), changedCourse("x"), timedOut("x"), couldNotAsk("x"),
         mayBeDone("x"), percentDone(40), kept(["a"]), kept(["a", "b", "c"]), notDone(["a", "b"]),
         TaskWrapUp(kept: [], notDone: []).keptLine]
        + TaskState.allCases.map(\.label)
    }
}

/// The list above can't miss a new digest line: every plain line written
/// in `DigestWords` is in it.
struct DigestWordsListTests {
    @Test func everyDigestLineIsChecked() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleCore/DigestTask.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(text.range(of: "public enum DigestWords"))
        let source = SwiftSource(String(text[start.lowerBound...]))
        let all = try DigestWords.all()
        let lines = source.literals.map(\.text).filter { !$0.contains("\\(") }
        #expect(lines.count >= 30, "the scan found too few lines")
        for line in lines { #expect(all.contains(line), "unchecked: \(line)") }
    }
}

extension DigestWords {
    /// Every line the digest task and its offer can show or say.
    /// `DigestWordsListTests` fails if a plain line is missing here.
    static func all() throws -> [String] {
        [offerHeading, offerDetail, startTitle, startHint, startInputLabel(DigestTask.title), reading, picking,
         writing, askLine, saving, done, removed, tookOut, nothingThisWeek, couldNotRead, couldNotSave, alreadyKept,
         tooLongToKeep, emptyDigest, hiddenQuote, notesLocked, stillInDigest, mayStillBeInDigest, earlierWordsInDigest,
         earlierWordsMayBeInDigest, noteChanged, cantSteer, cantDoThatYet, stoppedWhenClosed,
         yourNotes, heading, andMore(1), andMore(3), DigestTask.keep("x").question,
         TaskWords.declined(DigestTask.saveTodo),
         try #require(TaskWrapUp(kept: [], notDone: [DigestTask.saveTodo]).notDoneLine)]
    }
}
