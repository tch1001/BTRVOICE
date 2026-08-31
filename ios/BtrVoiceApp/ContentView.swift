// The rule-aware listening editor, editable draft, and compact-keyboard handoff.

import SwiftUI

struct ContentView: View {
  @StateObject private var transcriber = SpeechTranscriber()
  @ObservedObject private var rules = BetterVoiceRules.shared
  @State private var latest = SharedTranscriptStore.load()
  @State private var showingSettings = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          hero
          enginePicker
          if transcriber.engineMode.needsOpenAIKey, !transcriber.hasOpenAIKey {
            apiKeyCard
          }
          recorder
          if transcriber.isRecording {
            keyboardSessionCard
          }
          editor
          commitCard
          compactKeyboardCard
        }
        .padding(16)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(background.ignoresSafeArea())
      .navigationTitle("Better Voice")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingSettings = true
          } label: {
            Image(systemName: "gearshape.fill")
          }
          .accessibilityLabel("Better Voice settings")
        }
      }
      .sheet(isPresented: $showingSettings) {
        BetterVoiceSettingsView(transcriber: transcriber)
      }
      .onAppear { latest = SharedTranscriptStore.load() }
      .onOpenURL(perform: handleDeepLink)
    }
  }

  private var hero: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(.white.opacity(0.13))
          .frame(width: 62, height: 62)
        Image(systemName: "wand.and.stars.inverse")
          .font(.system(size: 27, weight: .semibold))
          .foregroundStyle(.white)
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("The listening editor")
          .font(.title2.bold())
          .foregroundStyle(.white)
        Text("Speak naturally. Correct yourself. Better Voice maintains the draft you meant.")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.78))
      }
      Spacer(minLength: 0)
    }
    .padding(20)
    .background(
      LinearGradient(
        colors: [Color(red: 0.20, green: 0.24, blue: 0.76), Color(red: 0.51, green: 0.22, blue: 0.76)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 24, style: .continuous)
    )
  }

  private var enginePicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Listening mode", selection: engineBinding) {
        ForEach(SpeechEngineMode.allCases) { mode in
          Text(mode.shortTitle).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .disabled(transcriber.isRecording)

      HStack(alignment: .top, spacing: 8) {
        Image(systemName: transcriber.engineMode == .listeningEditor ? "sparkles" : "info.circle")
          .foregroundStyle(Color.accentColor)
        Text(transcriber.engineMode.detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .cardStyle()
  }

  private var apiKeyCard: some View {
    HStack(spacing: 12) {
      Image(systemName: "key.fill")
        .font(.title2)
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("OpenAI key needed").font(.headline)
        Text("Add it once; Better Voice keeps it in the iPhone Keychain.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Add Key") { showingSettings = true }
        .buttonStyle(.borderedProminent)
    }
    .cardStyle()
  }

  private var recorder: some View {
    VStack(spacing: 12) {
      Button(action: transcriber.toggleRecording) {
        ZStack {
          Circle()
            .stroke(Color.accentColor.opacity(0.17), lineWidth: 12)
            .frame(width: 112, height: 112)
            .scaleEffect(1 + CGFloat(transcriber.level) * 0.14)
            .animation(.linear(duration: 0.08), value: transcriber.level)
          Circle()
            .fill(transcriber.isRecording ? Color.red : Color.accentColor)
            .frame(width: 88, height: 88)
          Image(systemName: transcriber.isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 32, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .buttonStyle(.plain)
      .disabled(transcriber.engineMode.needsOpenAIKey && !transcriber.hasOpenAIKey)
      .accessibilityLabel(transcriber.isRecording ? "Stop listening" : "Start listening")

      Text(transcriber.status)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if transcriber.engineMode == .listeningEditor, !transcriber.heardText.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text("HEARD")
            .font(.caption2.bold().monospaced())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary, in: Capsule())
          Text(transcriber.heardText)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Label("Editable draft", systemImage: "text.cursor")
          .font(.headline)
        if transcriber.editorPreview != nil {
          Text("EDITOR WRITING")
            .font(.caption2.bold().monospaced())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
        }
        Spacer()
        Button("Clear", action: transcriber.clear)
          .disabled(transcriber.transcript.isEmpty && transcriber.editorPreview == nil)
      }

      ZStack(alignment: .topLeading) {
        if let preview = transcriber.editorPreview {
          ScrollView {
            Text(preview)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(15)
          }
          .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        } else {
          TextEditor(text: $transcriber.transcript)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

          if transcriber.transcript.isEmpty {
            Text("Your edited transcript appears here live. You can also type or revise it directly.")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 16)
              .padding(.vertical, 19)
              .allowsHitTesting(false)
          }
        }
      }
      .frame(minHeight: 210)

      Button {
        showingSettings = true
      } label: {
        Label(
          rules.rules.isEmpty ? "Teach Better Voice a rule" : "\(rules.rules.count) remembered rule\(rules.rules.count == 1 ? "" : "s")",
          systemImage: "brain.head.profile"
        )
        .font(.footnote.weight(.semibold))
      }
      .buttonStyle(.borderless)
    }
    .cardStyle()
  }

  private var keyboardSessionCard: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill((transcriber.isProcessingAudio ? Color.red : Color.orange).opacity(0.14))
          .frame(width: 42, height: 42)
        Circle()
          .fill(transcriber.isProcessingAudio ? Color.red : Color.orange)
          .frame(width: 10, height: 10)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(transcriber.isProcessingAudio ? "Keyboard is listening" : "Keyboard session is armed")
          .font(.headline)
        Text("Switch to Telegram and use Listen or Pause in the compact keyboard. The microphone session stays armed in the background, but paused audio is dropped locally and never sent to GPT. Insert also pauses and clears the draft.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .cardStyle()
  }

  private var commitCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        guard let committed = SharedTranscriptStore.save(transcriber.transcript) else { return }
        latest = committed
        transcriber.markCommitted()
      } label: {
        Label("Commit Edited Draft", systemImage: "keyboard.badge.ellipsis")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 13)
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        transcriber.isRecording
          || transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )

      if let latest {
        Text("Ready for keyboard: \(latest.text)")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      } else {
        Text("Nothing has been committed for the keyboard yet.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .cardStyle()
  }

  private var compactKeyboardCard: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "keyboard.onehanded.left")
        .font(.title2)
        .foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 4) {
        Text("Compact keyboard extension").font(.headline)
        Text("No QWERTY rows: it shows the edited draft and gray live heard text above Listen/Pause, Insert, Trash, Space, and Backspace controls.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .cardStyle()
  }

  private var engineBinding: Binding<SpeechEngineMode> {
    Binding(
      get: { transcriber.engineMode },
      set: { transcriber.selectEngine($0) }
    )
  }

  private var background: some View {
    LinearGradient(
      colors: [Color(uiColor: .systemBackground), Color.accentColor.opacity(0.07)],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private func handleDeepLink(_ url: URL) {
    guard url.scheme == "btrvoice", url.host == "listen" else { return }
    transcriber.selectEngine(.listeningEditor)
    if transcriber.hasOpenAIKey {
      if !transcriber.isRecording { transcriber.toggleRecording() }
    } else {
      showingSettings = true
    }
  }
}

private extension View {
  func cardStyle() -> some View {
    padding(16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(Color.primary.opacity(0.06))
      )
  }
}

#Preview {
  ContentView()
}
