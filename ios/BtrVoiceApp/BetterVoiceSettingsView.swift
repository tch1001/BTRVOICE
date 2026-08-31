// API-key, engine, remembered-rule, and compact-keyboard settings for Better Voice.

import SwiftUI
import UIKit

struct BetterVoiceSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var transcriber: SpeechTranscriber
  @ObservedObject private var rules = BetterVoiceRules.shared

  @State private var apiKey = ""
  @State private var keyMessage = ""
  @State private var showingAddRule = false
  @State private var showingKeyboardSetup = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("Default engine", selection: engineBinding) {
            ForEach(SpeechEngineMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }

          ForEach(SpeechEngineMode.allCases) { mode in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: mode == .listeningEditor ? "wand.and.stars" : mode == .gptTranscription ? "waveform" : "iphone")
                .foregroundStyle(mode == transcriber.engineMode ? Color.accentColor : Color.secondary)
                .frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(mode.title).font(.subheadline.weight(.semibold))
                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        } header: {
          Text("Listening engine")
        }

        Section {
          HStack {
            Label(
              transcriber.hasOpenAIKey ? "API key configured" : "No API key configured",
              systemImage: transcriber.hasOpenAIKey ? "checkmark.shield.fill" : "key.fill"
            )
            .foregroundStyle(transcriber.hasOpenAIKey ? Color.green : Color.orange)
            Spacer()
          }

          SecureField("Paste OpenAI API key", text: $apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          Button("Save API Key") { saveAPIKey() }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          if transcriber.hasOpenAIKey {
            Button("Remove API Key", role: .destructive) {
              OpenAIKeyStore.clear()
              apiKey = ""
              keyMessage = "API key removed"
              transcriber.apiKeyDidChange()
            }
          }

          if !keyMessage.isEmpty {
            Text(keyMessage).font(.caption).foregroundStyle(.secondary)
          }
        } header: {
          Text("OpenAI")
        } footer: {
          Text("The key is stored in this iPhone’s Keychain. It is used only by the main Better Voice app and is never copied into the keyboard extension or the shared transcript.")
        }

        Section {
          if rules.rules.isEmpty {
            Text("No standing rules yet. Say “remember that…” while using the Listening Editor, or add one here.")
              .foregroundStyle(.secondary)
          }

          ForEach(Array(rules.rules.enumerated()), id: \.element.id) { index, rule in
            NavigationLink {
              RuleEditorView(number: index + 1, rule: rule)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text("Rule \(index + 1) · v\(rule.version)")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                Text(rule.text)
              }
            }
          }
          .onDelete { offsets in
            let ids = offsets.map { rules.rules[$0].id }
            for id in ids { rules.delete(id: id) }
          }

          Button {
            showingAddRule = true
          } label: {
            Label("Add Standing Rule", systemImage: "plus")
          }
        } header: {
          HStack {
            Text("Remembered rules")
            Spacer()
            Text("\(rules.rules.count)")
          }
        } footer: {
          Text("Rules are numbered and versioned like the Mac app. Spoken refinements update a rule instead of creating a near-duplicate.")
        }

        Section {
          Button("Compact Keyboard Setup") { showingKeyboardSetup = true }
          Button("Open App Settings") {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
          }
        }
      }
      .navigationTitle("Better Voice Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .sheet(isPresented: $showingAddRule) {
        AddRuleView()
      }
      .sheet(isPresented: $showingKeyboardSetup) {
        CompactKeyboardSetupView()
      }
    }
  }

  private var engineBinding: Binding<SpeechEngineMode> {
    Binding(
      get: { transcriber.engineMode },
      set: { transcriber.selectEngine($0) }
    )
  }

  private func saveAPIKey() {
    do {
      try OpenAIKeyStore.write(apiKey)
      apiKey = ""
      keyMessage = "API key saved securely"
      transcriber.apiKeyDidChange()
    } catch {
      keyMessage = "Could not save key: \(error.localizedDescription)"
    }
  }
}

private struct AddRuleView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""

  var body: some View {
    NavigationStack {
      Form {
        TextField("When I say…, write…", text: $text, axis: .vertical)
          .lineLimit(3...8)
      }
      .navigationTitle("New Rule")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            BetterVoiceRules.shared.add(text)
            dismiss()
          }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}

private struct RuleEditorView: View {
  @Environment(\.dismiss) private var dismiss
  let number: Int
  let rule: BetterVoiceRule
  @State private var text: String

  init(number: Int, rule: BetterVoiceRule) {
    self.number = number
    self.rule = rule
    _text = State(initialValue: rule.text)
  }

  var body: some View {
    Form {
      Section("Rule \(number)") {
        TextField("Standing rule", text: $text, axis: .vertical)
          .lineLimit(4...10)
      }
      Section("History") {
        if rule.history.isEmpty {
          Text("No previous versions").foregroundStyle(.secondary)
        } else {
          ForEach(Array(rule.history.enumerated()), id: \.offset) { index, oldText in
            VStack(alignment: .leading, spacing: 2) {
              Text("v\(index + 1)").font(.caption).foregroundStyle(.secondary)
              Text(oldText)
            }
          }
        }
      }
      Section {
        Button("Delete Rule", role: .destructive) {
          BetterVoiceRules.shared.delete(id: rule.id)
          dismiss()
        }
      }
    }
    .navigationTitle("Edit Rule")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          BetterVoiceRules.shared.update(id: rule.id, text: text)
          dismiss()
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == rule.text)
      }
    }
  }
}

struct CompactKeyboardSetupView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("Enable Better Voice") {
          setupRow(1, "Open Settings", "Go to General › Keyboard › Keyboards.")
          setupRow(2, "Add New Keyboard", "Choose Better Voice Keyboard.")
          setupRow(3, "Allow Full Access", "This lets the compact keyboard read only the draft you explicitly commit.")
        }
        Section("Compact by design") {
          Text("The extension has no QWERTY rows. Its controls are Listen/Pause, Insert, Trash, Space, and Backspace, leaving Telegram’s composer visible.")
        }
        Section("Use it in Telegram") {
          Text("Start the Listening Editor once, then switch to Telegram. Use Pause and Listen without leaving Telegram. The microphone remains armed while paused, but audio is dropped locally instead of being sent to GPT. Tap Insert to insert, clear, and pause.")
        }
      }
      .navigationTitle("Compact Keyboard")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }

  private func setupRow(_ number: Int, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.caption.bold())
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Color.accentColor, in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}
