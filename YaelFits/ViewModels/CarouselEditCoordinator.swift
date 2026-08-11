import Foundation
import Observation

/// Single source of truth for the carousel detail card's edit
/// session. Replaces the previous binding-and-callback dance
/// between `CarouselView` and `CarouselDetailCard` — both views now
/// observe one `@Observable` object and call its methods directly.
///
/// Also fixes a subtle bug in the old plumbing: editing was scoped
/// to whatever outfit happened to be `currentOutfit` *at save time*.
/// If the user opened the card, started editing outfit A, then
/// scrolled to outfit B before tapping Save, the edits would commit
/// against B. The coordinator snapshots the outfit when editing
/// starts so Save always targets the same outfit the user was
/// editing.
@Observable
final class CarouselEditCoordinator {
    /// True while the card is in edit mode. Drives Cancel/Save
    /// affordances in the card and the editable date/location row
    /// in the carousel chrome.
    var isEditing = false

    // MARK: - Working values (committed on Save, discarded on Cancel)

    var editableDate: Date = Date()
    var editableLocation: String = ""
    var editableTags: [String] = []

    /// Presentation flag for the date picker sheet.
    var showDatePicker = false

    /// The outfit captured at edit-start. Save targets this
    /// specific outfit even if the carousel has scrolled to a
    /// different one before commit.
    private(set) var editingOutfit: Outfit?

    /// Location text input cap (matches the prior in-card constant).
    static let locationMaxLength = 30

    // MARK: - Lifecycle

    func startEditing(_ outfit: Outfit) {
        editingOutfit = outfit
        editableDate = outfit.parsedDate ?? Date()
        editableLocation = outfit.location ?? ""
        editableTags = outfit.tags ?? []
        isEditing = true
    }

    func save(into store: OutfitStore) {
        defer {
            isEditing = false
            editingOutfit = nil
        }
        guard let outfit = editingOutfit else { return }
        let outfitId = outfit.id

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let newDateString = formatter.string(from: editableDate)
        let dateChanged = newDateString != outfit.date
        if dateChanged {
            store.updateOutfitDate(outfitId: outfitId, date: newDateString)
            Task { try? await OutfitService.updateOutfitDate(outfitId: outfitId, date: newDateString) }
        }

        let trimmedLocation = editableLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmedLocation.isEmpty ? nil : trimmedLocation
        let locationChanged = normalized != outfit.location
        if locationChanged {
            store.updateOutfitLocation(outfitId: outfitId, location: normalized)
            Task { try? await OutfitService.updateOutfitLocation(outfitId: outfitId, location: normalized) }
        }

        // Weather follows the fit: a new date and/or place means the
        // pill re-derives for that day at that location (WeatherKit
        // history). Empty/un-geocodable location → the pill CLEARS —
        // showing the old weather under a new date would be a lie.
        if dateChanged || locationChanged {
            let day = editableDate
            let place = normalized
            Task { @MainActor in
                let weather = await UploadWeatherService.shared.weather(forPlaceName: place, onDay: day)
                store.updateOutfitWeather(outfitId: outfitId, weather: weather)
                try? await OutfitService.updateOutfitWeather(outfitId: outfitId, weather: weather)
            }
        }

        let originalTags = outfit.tags ?? []
        if editableTags != originalTags {
            store.updateOutfitTags(outfitId: outfitId, tags: editableTags)
            Task { try? await ProductLibraryService.updateOutfitTags(outfitId: outfitId, tags: editableTags) }
        }
    }

    /// Discard in-flight edits. Cheaper and clearer than the
    /// previous "re-seed values so the commit becomes a no-op"
    /// trick — nothing is written to the store.
    func cancel() {
        isEditing = false
        editingOutfit = nil
    }
}
