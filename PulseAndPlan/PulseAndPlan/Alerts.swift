@preconcurrency import EventKit
@preconcurrency import MapKit
import MessageUI
import SwiftUI
import UserNotifications

// MARK: - Local notifications

/// Local notifications need no paid entitlement. They only fire while iOS keeps the app alive
/// (foreground, or background thanks to location updates); waking a killed app needs APNs.
enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(title: String, body: String, after seconds: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0, 1), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger),
                                               withCompletionHandler: nil)
    }
}

// MARK: - iMessage

struct MessageDraft: Identifiable {
    let id = UUID()
    var body: String
}

/// Opens Messages pre-filled to your partner; falls back to the share sheet where Messages can't open (Simulator).
struct MessageSheet: View {
    let draft: MessageDraft
    let phone: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if MFMessageComposeViewController.canSendText() {
            MessageComposer(recipients: phone.isEmpty ? [] : [phone], body: draft.body) { dismiss() }
                .ignoresSafeArea()
        } else {
            ShareSheet(items: [draft.body])
        }
    }
}

struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    // MessageUI calls the delegate on the main thread but its protocol predates Swift concurrency.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onDone()
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Calendar (EventKit)

@MainActor
final class CalendarBridge {
    private let store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Busy intervals from every calendar on the phone (Google/Outlook too, if synced to iOS). Titles never leave the phone.
    func busyIntervals(from start: Date, days: Int) -> [DateInterval] {
        guard hasAccess, let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free && $0.endDate > $0.startDate }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }

    func add(_ event: SharedEvent, partnerName: String) throws {
        let item = EKEvent(eventStore: store)
        item.title = event.title
        item.startDate = event.start
        item.endDate = event.end
        item.notes = "Planned with \(partnerName) in Red Thread"
        item.calendar = store.defaultCalendarForNewEvents
        try store.save(item, span: .thisEvent)
    }
}

// MARK: - Travel time

enum TravelTime {
    /// Driving ETA, or nil when there's no road route (e.g. different continents).
    static func eta(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }
}
