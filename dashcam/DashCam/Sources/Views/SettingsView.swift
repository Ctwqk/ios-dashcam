import SwiftUI
import DashCamCore

struct SettingsView: View {
    @Binding var config: DashcamConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("settings.section.recording")) {
                    Picker(NSLocalizedString("settings.loopDuration", comment: ""), selection: $config.bufferMinutes) {
                        ForEach(BufferDurationOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }

                    HStack {
                        Text("settings.segmentLength")
                        Spacer()
                        Text("settings.segmentLength.value")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("settings.resolution")
                        Spacer()
                        Text(config.resolution.rawValue)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("settings.codec")
                        Spacer()
                        Text(config.codec.rawValue)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("settings.hdr")
                        Spacer()
                        Text("settings.off")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("settings.stabilization")
                        Spacer()
                        Text("settings.off")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("settings.lens")
                        Spacer()
                        Text("settings.lens.wide")
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("settings.section.collision")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("settings.sensitivity")
                            Spacer()
                            Text(String(format: "%.1fg", config.collisionThreshold))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $config.collisionThreshold, in: 1.5...6.0, step: 0.5)
                    }
                    Text("settings.sensitivity.hint")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("settings.section.collisionBehavior")) {
                    Text("settings.collisionBehavior.auto")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("settings.collisionBehavior.manual")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("settings.section.power")) {
                    Text("settings.power.config")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("settings.power.dimming")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("settings.section.storage")) {
                    HStack {
                        Text("settings.estimatedUsage")
                        Spacer()
                        Text(estimatedStorage)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("settings.section.about")) {
                    HStack {
                        Text("settings.version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("settings.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("settings.done", comment: "")) {
                        config.save()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Size of a full loop, from the encoder's configured bit rates (not a guess per minute).
    private var estimatedStorage: String {
        ByteCountFormatter.string(fromByteCount: config.estimatedBufferBytes, countStyle: .file)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
