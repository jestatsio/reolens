import SwiftUI
import ReolinkAPI

/// Per-category notification toggles — the "Event types" picker. 0.8.2
/// replaced the old `notifyAI` master + `Motion only` toggle pair (which
/// read as mutually exclusive but weren't, and let motion leak through on
/// the relay path) with a single list where every detection category —
/// Motion, Person, Vehicle, Pet, … — is an independent switch.
///
/// Backed by `EventNotifier.notifyPerTag` (which now includes `.motion`).
/// A category that's off never fires a notification, on any device, even
/// when the camera triggers it.
public struct NotificationCategoriesSection: View {
    @Bindable public var notifier: EventNotifier
    public var categories: [DetectionType]

    public init(
        notifier: EventNotifier,
        categories: [DetectionType] = DetectionType.allCases
    ) {
        self.notifier = notifier
        self.categories = categories
    }

    public var body: some View {
        Section("Event types") {
            ForEach(categories, id: \.self) { tag in
                Toggle(isOn: binding(for: tag)) {
                    Label(tag.label, systemImage: tag.systemImage)
                }
            }
            Text("Pick which detections fire notifications — each is independent. Motion is off by default: it can flood when sustained. The AI categories (person, vehicle, pet, …) only fire when the camera classifies the trigger.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(!notifier.enabled)
    }

    private func binding(for tag: DetectionType) -> Binding<Bool> {
        Binding(
            get: { notifier.isCategoryEnabled(tag) },
            set: { newValue in
                var copy = notifier.notifyPerTag
                copy[tag] = newValue
                notifier.notifyPerTag = copy
            }
        )
    }
}
