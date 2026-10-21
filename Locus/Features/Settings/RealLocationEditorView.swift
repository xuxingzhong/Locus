import MapKit
import SwiftUI

/// Search resolves editable human-readable place names into actual coordinates.
/// Never interpret arbitrary edited text as a coordinate without search selection.
struct RealLocationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var realLocation = RealLocationStore.shared

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var selectedPlace: MKMapItem?
    @State private var displayName = ""
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search for a place or address", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await searchPlaces() } }
                    Button {
                        Task { await searchPlaces() }
                    } label: {
                        if isSearching {
                            ProgressView()
                        } else {
                            Label("Search places", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let searchError {
                        Text(searchError).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Search and select a real place. Its name is editable, but the coordinate comes from the selected result.")
                }

                if !results.isEmpty {
                    Section("Matching places") {
                        ForEach(results.indices, id: \.self) { index in
                            let place = results[index]
                            Button {
                                selectedPlace = place
                                displayName = suggestedName(for: place)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.name ?? String(localized: "Unnamed place"))
                                        .foregroundStyle(.primary)
                                    if let description = place.placemark.title {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }

                if selectedPlace != nil {
                    Section("Selected recovery location") {
                        TextField("Display name", text: $displayName)
                        Button("Save recovery location") {
                            guard let place = selectedPlace else { return }
                            realLocation.saveManual(
                                coordinate: place.placemark.coordinate,
                                address: displayName
                            )
                            dismiss()
                        }
                        .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        Text("This manually selected place will be used as a nearby transition before clearing simulation. Update it if you travel.")
                    }
                }
            }
            .navigationTitle("Edit real location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { query = realLocation.saved?.address ?? "" }
        }
    }

    @MainActor
    private func searchPlaces() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSearching else { return }
        isSearching = true
        searchError = nil
        selectedPlace = nil
        results = []
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems.filter {
                CLLocationCoordinate2DIsValid($0.placemark.coordinate)
            }
            if results.isEmpty { searchError = String(localized: "No matching places found. Try a more complete address.") }
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func suggestedName(for place: MKMapItem) -> String {
        let name = place.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullAddress = place.placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return fullAddress }
        if fullAddress.isEmpty || fullAddress.contains(name) { return fullAddress.isEmpty ? name : fullAddress }
        return name + " · " + fullAddress
    }
}
