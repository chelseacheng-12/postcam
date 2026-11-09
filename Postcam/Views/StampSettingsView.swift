import SwiftUI
import UIKit

struct StampSettingsView: View {
    @ObservedObject var settings: StampSettings
    let compositor: StampCompositor
    @Environment(\.dismiss) private var dismiss
    @State private var proof: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    proofView
                } footer: {
                    Text("The date is the month you shoot or upload. The other lines print in capitals.")
                }

                Section("Stamp text") {
                    LabeledContent("Date") {
                        Text(settings.datePreview)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    TextField("Label", text: $settings.label)
                        .textInputAutocapitalization(.characters)
                    TextField("Caption", text: $settings.caption)
                        .textInputAutocapitalization(.characters)
                    TextField("Denomination", text: $settings.denomination)
                        .textInputAutocapitalization(.characters)
                    TextField("Place", text: $settings.place)
                        .textInputAutocapitalization(.characters)
                }

                Section {
                    Button("Reset to the Hong Kong stamp") {
                        settings.reset()
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
        .tint(PostcamColor.vermilionColor)
        .task(id: settings.revision) {
            let copy = settings.copyForCurrentFrame()
            let rendered = await compositor.proof(copy: copy)
            if let rendered, !Task.isCancelled {
                proof = rendered
            }
        }
    }

    @ViewBuilder
    private var proofView: some View {
        ZStack {
            if let proof {
                Image(uiImage: proof)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .accessibilityLabel("Stamp preview")
    }
}
