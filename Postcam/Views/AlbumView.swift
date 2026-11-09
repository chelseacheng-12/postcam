import PhotosUI
import SwiftUI
import UIKit

struct AlbumView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedID: UUID?
    @State private var pendingDelete: CaptureItem?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if model.store.captures.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(model.store.captures) { item in
                                Button {
                                    selectedID = item.id
                                } label: {
                                    ThumbnailCell(
                                        url: model.store.thumbURL(for: item),
                                        isVideo: item.kind == .video,
                                        duration: item.duration
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        pendingDelete = item
                                    }
                                }
                            }
                        }
                        .padding(2)
                    }
                }
            }
            .background(Color(red: 0.97, green: 0.97, blue: 0.97))
            .navigationTitle("Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text("Upload")
                    }
                    .disabled(model.isImporting)
                }
            }
            .overlay {
                if model.isImporting {
                    importingOverlay
                }
            }
            .fullScreenCover(isPresented: viewerPresented) {
                CaptureViewer(store: model.store, selection: $selectedID)
            }
            .confirmationDialog(
                "Delete this capture?",
                isPresented: deletePresented,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDelete {
                        model.store.delete(pendingDelete)
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await importItem(item) }
            }
        }
        .preferredColorScheme(.light)
        .tint(PostcamColor.vermilionColor)
    }

    private var viewerPresented: Binding<Bool> {
        Binding(
            get: { selectedID != nil },
            set: { if !$0 { selectedID = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing on the roll")
                .font(.title3.weight(.semibold))
            Text("Photos and videos you take in Postcam land here with the stamp printed on. Upload a picture from your library to stamp it without shooting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Upload")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(PostcamColor.vermilionColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)
            .disabled(model.isImporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Printing stamp")
                    .font(.subheadline.weight(.medium))
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func importItem(_ item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.showBanner("That photo couldn't be loaded.")
                return
            }
            model.importPhoto(data)
        } catch {
            model.showBanner("That photo couldn't be loaded. If it's in iCloud, download it in Photos and try again.")
        }
    }
}

private struct ThumbnailCell: View {
    var url: URL
    var isVideo: Bool
    var duration: TimeInterval?
    @State private var image: UIImage?

    var body: some View {
        Color(red: 0.9, green: 0.9, blue: 0.9)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isVideo {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                        if let duration {
                            Text(DurationFormat.clock(duration))
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 0)
                    .padding(6)
                }
            }
            .clipped()
            .task(id: url) {
                let path = url.path
                let loaded = await Task.detached(priority: .utility) {
                    UIImage(contentsOfFile: path)
                }.value
                image = loaded
            }
    }
}
