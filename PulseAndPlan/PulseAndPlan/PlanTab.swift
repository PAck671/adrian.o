import SwiftUI

/// Free-window math for the dual timeline. Awake = 08:00–23:00 local; a `.busy` block from either of you removes the hour.
enum Overlap {
    static let awake = 8..<23

    static func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    /// The 24 hour-start instants of `day` as seen in `tz` (23/25 around DST changes).
    static func hours(of day: Date, in tz: TimeZone) -> [Date] {
        let cal = calendar(tz)
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return stride(from: start, to: end, by: 3600).map { $0 }
    }

    static func isAwake(_ date: Date, in tz: TimeZone) -> Bool {
        awake.contains(calendar(tz).component(.hour, from: date))
    }

    static func bothFree(_ hour: Date, myTZ: TimeZone, partnerTZ: TimeZone, events: [SharedEvent]) -> Bool {
        let end = hour.addingTimeInterval(3600)
        let busy = events.filter { $0.kind == .busy && $0.start < end && $0.end > hour }
        return isAwake(hour, in: myTZ) && isAwake(hour, in: partnerTZ) && busy.isEmpty
    }
}

struct PlanTab: View {
    @Environment(AppState.self) private var state
    @State private var day = Date()
    @State private var editingVisit = false
    @State private var newEventStart: Date?
    @State private var section = 0
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CountdownCard(visit: state.visit)
                    .onTapGesture { editingVisit = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Edit the visit")
                Picker("Section", selection: $section.animation(.spring)) {
                    Text("Calendar").tag(0)
                    Text("Notes (\(state.notes.count))").tag(1)
                }
                .pickerStyle(.segmented)
                Group {
                    if section == 0 {
                        VStack(alignment: .leading, spacing: 18) {
                            calendarBar
                            timeline
                            eventsList
                        }
                    } else {
                        NotesBoard()
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: section == 0 ? .leading : .trailing).combined(with: .opacity),
                                        removal: .opacity))
            }
            .padding()
        }
        .sheet(isPresented: $editingVisit) { VisitEditor(visit: state.visit) }
        .sheet(item: Binding(get: { newEventStart.map(IdentifiedDate.init) }, set: { newEventStart = $0?.date })) {
            EventEditor(start: $0.date)
        }
    }

    // MARK: Device calendar

    private var calendarBar: some View {
        HStack {
            Button {
                importing = true
                Task {
                    let count = await state.importCalendarBusy()
                    importing = false
                    state.showToast(count.map { "Shared \($0) busy blocks from your calendar (titles stay private)." }
                                    ?? "Calendar access is off. Turn it on in iOS Settings → Pulse & Plan.")
                }
            } label: {
                Label(importing ? "Reading calendar…" : state.settings.syncCalendar ? "Refresh my busy times" : "Share my busy times",
                      systemImage: "calendar.badge.clock")
            }
            .buttonStyle(.bordered)
            .disabled(importing)
            Spacer()
        }
    }

    // MARK: Dual timeline

    private var timeline: some View {
        let myTZ = state.myTZ, partnerTZ = state.partnerTZ
        let hours = Overlap.hours(of: day, in: myTZ)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                Spacer()
                Text(day.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: myTZ))).font(.headline)
                Spacer()
                Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next day")
            }
            HStack {
                Text("My time · \(myTZ.abbreviation() ?? myTZ.identifier)").frame(maxWidth: .infinity, alignment: .leading)
                Text("\(state.settings.partnerName) · \(partnerTZ.abbreviation() ?? partnerTZ.identifier)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                ForEach(hours, id: \.self) { hour in
                    hourRow(hour, myTZ: myTZ, partnerTZ: partnerTZ)
                }
            }
            HStack(spacing: 14) {
                legend(.green.opacity(0.45), "Both free")
                legend(.white.opacity(0.08), "Awake")
                legend(.clear, "Asleep")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Tap a green hour to plan something then.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func hourRow(_ hour: Date, myTZ: TimeZone, partnerTZ: TimeZone) -> some View {
        let free = Overlap.bothFree(hour, myTZ: myTZ, partnerTZ: partnerTZ, events: state.events)
        let iAwake = Overlap.isAwake(hour, in: myTZ), theyAwake = Overlap.isAwake(hour, in: partnerTZ)
        let hourEnd = hour.addingTimeInterval(3600)
        let overlapping = state.events.filter { $0.start < hourEnd && $0.end > hour }
        return Button { newEventStart = hour } label: {
            HStack(spacing: 8) {
                Text(timeLabel(hour, myTZ, reference: myTZ))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(iAwake ? .white.opacity(0.08) : .clear))
                Text(timeLabel(hour, partnerTZ, reference: myTZ))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theyAwake ? .white.opacity(0.08) : .clear))
            }
            .font(.subheadline.monospacedDigit())
            .overlay(alignment: .trailing) {
                HStack(spacing: 4) {
                    ForEach(overlapping) { event in
                        Text(event.title)
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(event.kind.color.opacity(0.8)))
                    }
                }
                .padding(.trailing, 6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(free ? Color.green.opacity(0.35) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(timeLabel(hour, myTZ, reference: myTZ)) for you, \(timeLabel(hour, partnerTZ, reference: myTZ)) for \(state.settings.partnerName)\(free ? ", both free" : "")")
    }

    /// "9 AM", plus the weekday when that zone is on a different day.
    private func timeLabel(_ date: Date, _ tz: TimeZone, reference: TimeZone) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz))
        let sameDay = Overlap.calendar(tz).component(.weekday, from: date) == Overlap.calendar(reference).component(.weekday, from: day)
        return sameDay ? time : "\(date.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated))) \(time)"
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.2)))
            Text(label)
        }
    }

    private func shiftDay(_ days: Int) {
        day = Overlap.calendar(state.myTZ).date(byAdding: .day, value: days, to: day) ?? day
    }

    // MARK: Events

    private var eventsList: some View {
        let upcoming = state.events.filter { $0.end > Date() }.sorted { $0.start < $1.start }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shared plans").font(.headline)
                Spacer()
                Button { newEventStart = Date() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            if upcoming.isEmpty {
                Text("Nothing planned yet. Add a date night, a call, or the hours you're busy.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(upcoming) { event in
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2).fill(event.kind.color).frame(width: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(.subheadline.bold())
                        Text("You: \(event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: state.myTZ)))")
                        Text("\(state.settings.partnerName): \(event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: state.partnerTZ)))")
                    }
                    .font(.caption)
                    Spacer()
                    Text(event.kind.label).font(.caption2.bold()).foregroundStyle(event.kind.color)
                    if event.fromCalendar != true {
                        Button { Task { await state.addToCalendar(event) } } label: { Image(systemName: "calendar.badge.plus") }
                            .accessibilityLabel("Add \(event.title) to my calendar")
                        Button {
                            let when = event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: state.partnerTZ))
                            state.textPartner("📅 \(event.title) · \(when) your time")
                        } label: { Image(systemName: "message") }
                            .accessibilityLabel("Text \(state.settings.partnerName) about \(event.title)")
                    }
                    Button(role: .destructive) { state.deleteEvent(event) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete \(event.title)")
                }
                .buttonStyle(.borderless)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            }
        }
    }
}

private struct IdentifiedDate: Identifiable {
    let date: Date
    var id: Date { date }
}

// MARK: - Countdown

struct CountdownCard: View {
    let visit: Visit

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let parts = Calendar.current.dateComponents([.day, .hour, .minute, .second], from: context.date, to: visit.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Next visit", systemImage: "airplane").font(.subheadline.bold())
                    Spacer()
                    Image(systemName: "pencil.circle.fill").font(.title3)
                }
                Text(visit.destination.isEmpty ? "Somewhere together" : visit.destination).font(.title.bold())
                if visit.date > context.date {
                    HStack(spacing: 14) {
                        unit(parts.day, "days")
                        unit(parts.hour, "hrs")
                        unit(parts.minute, "min")
                        unit(parts.second, "sec")
                    }
                } else {
                    Text("Together now 💞").font(.title2.bold())
                }
                Text(visit.date.formatted(date: .long, time: .shortened)).font(.caption).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: visit.theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }

    private func unit(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text("\(max(value ?? 0, 0))").font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
            Text(label).font(.caption2.bold()).opacity(0.8)
        }
    }
}

// MARK: - Editors

struct VisitEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var visit: Visit

    var body: some View {
        NavigationStack {
            Form {
                TextField("Destination", text: $visit.destination)
                DatePicker("Arrival", selection: $visit.date, in: Date()...)
                Picker("Theme", selection: $visit.theme) {
                    ForEach(VisitTheme.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                CountdownCard(visit: visit).listRowInsets(EdgeInsets())
            }
            .navigationTitle("Next Visit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.saveVisit(visit)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct EventEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: EventKind = .dateNight
    @State private var start: Date
    @State private var minutes = 60

    init(start: Date) { _start = State(initialValue: start) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title (e.g. Movie night)", text: $title)
                Picker("Type", selection: $kind) {
                    ForEach(EventKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Starts", selection: $start)
                    .environment(\.timeZone, state.myTZ)
                Picker("Length", selection: $minutes) {
                    ForEach([30, 60, 90, 120, 180, 240], id: \.self) { m in
                        Text(m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60).5 h").tag(m)
                    }
                }
                Section("Converted") {
                    LabeledContent("You", value: start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: state.myTZ)))
                    LabeledContent(state.settings.partnerName,
                                   value: start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: state.partnerTZ)))
                }
                if kind == .busy {
                    Text("Busy blocks remove this time from the green \"both free\" windows.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        state.saveEvent(SharedEvent(title: title.isEmpty ? kind.label : title, kind: kind, start: start,
                                                    end: start.addingTimeInterval(Double(minutes) * 60),
                                                    createdBy: state.settings.deviceId))
                        dismiss()
                    }
                }
            }
        }
    }
}
