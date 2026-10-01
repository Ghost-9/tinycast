import SwiftUI

/// One meeting's page. ↵, ⌘↵ and ⌘K act on it exactly as on its schedule row.
struct MeetingDetailsScreen: PaletteScreen {
    let store: CalendarStore
    let core: AppCore

    private var meeting: MeetingEvent? {
        store.details.flatMap { store.event(id: $0.meetingID) }
    }

    var rows: [MeetingEvent] { meeting.map { [$0] } ?? [] }

    var primaryActionTitle: String {
        meeting?.link == nil ? "Open in Calendar" : "Join Meeting"
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        meeting.map { MeetingActionsMenu.content(meeting: $0, core: core, offersDetails: false) }
    }

    func activate(at selection: Int) {
        guard let meeting else { return }
        core.calendarCoordinator.join(meeting)
    }

    func secondary(at selection: Int) -> Bool {
        guard let meeting, meeting.link != nil else { return false }
        core.calendarCoordinator.copyLink(meeting)
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        guard let details = store.details, let meeting = store.event(id: details.meetingID) else {
            return AnyView(EmptyResults(text: "This meeting is no longer available"))
        }
        return AnyView(MeetingDetailsView(meeting: meeting, details: details))
    }
}
