import CoreLocation
import EventKit
import Foundation

/// What the New Meeting sheet offers: meetings on his calendar right now, and
/// (optionally) where he is. Both ask permission the first time and degrade to
/// "nothing to offer" when refused — a title can always be typed.
@MainActor
final class MeetingContext: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Meeting: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let location: String?
        let calendarColor: CGColor?
        static func == (a: Meeting, b: Meeting) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var calendarNote: String?
    @Published private(set) var place: String?
    @Published private(set) var locating = false
    @Published private(set) var locationNote: String?

    private let store = EKEventStore()
    private let manager = CLLocationManager()

    /// Events overlapping now, from 15 min ago to 30 min ahead, not all-day,
    /// nearest start first.
    func loadMeetings(now: Date = Date()) async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPIEL_FAKE_MEETINGS"] == "1" {
            meetings = [
                Meeting(id: "a", title: "DÆMON hip bearing review", start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1500),
                        location: "Workshop", calendarColor: CGColor(red: 0.2, green: 0.7, blue: 1, alpha: 1)),
                Meeting(id: "b", title: "Spiel iPhone planning", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
                        location: nil, calendarColor: CGColor(red: 1, green: 0.5, blue: 0.3, alpha: 1)),
            ]
            return
        }
        #endif
        do {
            guard try await store.requestFullAccessToEvents() else {
                calendarNote = "Calendar access is off (Settings › Spiel › Calendars)."
                return
            }
        } catch {
            calendarNote = "Calendar unavailable: \(error.localizedDescription)"
            return
        }
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60),
                                            end: now.addingTimeInterval(30 * 60), calendars: nil)
        meetings = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now.addingTimeInterval(-5 * 60) }
            .sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
            .map { e in
                Meeting(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Untitled event",
                        start: e.startDate, end: e.endDate,
                        location: e.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        calendarColor: e.calendar?.cgColor)
            }
        if meetings.isEmpty { calendarNote = "Nothing on your calendar right now." }
    }

    func locate() {
        locationNote = nil
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationNote = "Location access is off (Settings › Spiel › Location)."
            return
        default: break
        }
        locating = true
        manager.requestLocation()
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in
            let p = marks?.first
            // "Blue Star Donuts, Portland" — the place's name if it has one, then the town.
            let name = [p?.areasOfInterest?.first ?? p?.name, p?.locality]
                .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ", ")
            let fallback = String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.place = name.isEmpty ? fallback : name
                    self.locating = false
                }
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.locating = false
                self.locationNote = "Couldn't get a location."
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if s == .denied || s == .restricted {
                    self.locating = false
                    self.locationNote = "Location access is off (Settings › Spiel › Location)."
                }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
