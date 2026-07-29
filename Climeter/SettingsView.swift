import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var profileManager: ProfileManager
    @State private var editingProfileID: UUID?
    @State private var editingName: String = ""
    @State private var launchAtLogin: Bool = LaunchAtLoginService.isEnabled
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLoginService.toggle()
                        } catch {
                            launchAtLogin = !newValue
                            errorMessage = "Failed to toggle Launch at Login: \(error.localizedDescription)"
                            showError = true
                        }
                    }
            }

            Section("Claude (Anthropic)") {
                Toggle("Show Claude usage", isOn: $profileManager.claudeEnabled)

                Picker("Usage source", selection: $profileManager.claudeUsageSource) {
                    Text("Claude Code status line — password-free")
                        .tag(ClaudeUsageSource.statusLineFile)
                    Text("macOS Keychain — may ask for password")
                        .tag(ClaudeUsageSource.keychainManual)
                }
                .pickerStyle(.menu)

                if profileManager.claudeUsageSource == .keychainManual {
                    Text("Compatibility mode may trigger a macOS password prompt.")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Text("Run /login in Claude Code to connect accounts. Auto-switch applies only to Claude profiles.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Usage updates after Claude Code responds. No OAuth credential is read.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Codex") {
                Toggle("Show Codex usage", isOn: $profileManager.codexEnabled)

                HStack {
                    Text("Credentials")
                    Spacer()
                    Text(CodexCredentialStore.authFileURL().path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(CodexCredentialStore.authFileURL().path)
                }

                if let error = profileManager.codexErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if profileManager.codexUsageData != nil {
                    Text("Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Run `codex login` if usage does not appear.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Peak Hours") {
                Toggle("Show peak hours indicator", isOn: $profileManager.peakHoursEnabled)

                Text("Weekdays \(PeakHoursService.localTimeRangeString()). Session limits are consumed faster during peak hours.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Auto-Switch") {
                Toggle("Switch accounts automatically", isOn: $profileManager.autoSwitchEnabled)
                    .disabled(profileManager.claudeUsageSource == .statusLineFile)

                if profileManager.autoSwitchEnabled {
                    HStack {
                        Text("Threshold")
                        Slider(value: $profileManager.autoSwitchThreshold, in: 50...100, step: 5)
                        Text("\(Int(profileManager.autoSwitchThreshold))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .disabled(profileManager.claudeUsageSource == .statusLineFile)
                }

                if profileManager.claudeUsageSource == .statusLineFile {
                    Text("Requires Keychain compatibility mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Profiles") {
                ForEach(profileManager.profiles) { profile in
                    HStack {
                        if editingProfileID == profile.id {
                            TextField("Profile name", text: $editingName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { commitRename() }
                        } else {
                            Text(profile.name)
                                .foregroundColor(profileManager.cliActiveProfileID == profile.id ? .primary : .secondary)
                        }

                        if profileManager.cliActiveProfileID == profile.id {
                            Image(systemName: "terminal")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Spacer()

                        if editingProfileID == profile.id {
                            Button("Done") { commitRename() }
                                .buttonStyle(.borderless)
                        } else {
                            Button(action: { startEditing(profile: profile) }) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }

                        Button(action: { profileManager.deleteProfile(id: profile.id) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(profileManager.profiles.count <= 1)
                    }
                    .padding(.vertical, 2)
                }

                Button("Add Profile") {
                    profileManager.createProfile(name: "New Profile")
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 700)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func startEditing(profile: Profile) {
        editingProfileID = profile.id
        editingName = profile.name
    }

    private func commitRename() {
        guard let id = editingProfileID else { return }
        profileManager.renameProfile(id: id, name: editingName)
        editingProfileID = nil
        editingName = ""
    }
}

#Preview {
    SettingsView(profileManager: ProfileManager())
}
