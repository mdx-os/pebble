import Foundation

/// The reasons a calendar read gives when it can't answer, in the voice of
/// docs/VOICE.md: plain, kind, no dashes, and never a promise about where
/// words go. Each says what happened and what the person can do.
public enum CalendarWords {
    public static func reason(_ why: CalendarBlock.Why, kind: CalendarKind) -> String {
        switch (why, kind) {
        case (.notAskedYet, .events):
            "I haven't looked at your calendar, because you haven't said yes yet. "
                + "When you ask me about your day, I'll ask you first."
        case (.notAskedYet, .reminders):
            "I haven't looked at your reminders, because you haven't said yes yet. "
                + "When you ask me about them, I'll ask you first."
        case (.denied, .events):
            "You chose not to let me see your calendar, so I can't tell what's on it. "
                + "You can change that in Settings anytime."
        case (.denied, .reminders):
            "You chose not to let me see your reminders, so I can't tell what's due. "
                + "You can change that in Settings anytime."
        case (.restricted, .events):
            "A setting I can't change keeps your calendar closed to me, like one from work or school. "
                + "So I can't tell what's on it."
        case (.restricted, .reminders):
            "A setting I can't change keeps your reminders closed to me, like one from work or school. "
                + "So I can't tell what's due."
        case (.writeOnly, .events):
            "I may add to your calendar but not read it, so I can't tell what's on it. "
                + "You can let me see it in Settings."
        case (.writeOnly, .reminders):
            "I may add reminders but not read them, so I can't tell what's due. "
                + "You can let me see them in Settings."
        case (.couldNotRead, .events):
            "Sorry, I couldn't read your calendar just now. Try again in a moment."
        case (.couldNotRead, .reminders):
            "Sorry, I couldn't read your reminders just now. Try again in a moment."
        }
    }

    /// Every reason, for the copy checks.
    public static var all: [String] {
        CalendarBlock.Why.allCases.flatMap { why in CalendarKind.allCases.map { reason(why, kind: $0) } }
    }
}
