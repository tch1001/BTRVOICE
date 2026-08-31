// A compact live-draft pad fed by the containing app's background listening session.

import UIKit

final class KeyboardViewController: UIInputViewController {
  private enum PendingDraftReset {
    case clear
    case finish
  }

  private let draftView = UITextView()
  private let listeningButton = UIButton(type: .system)
  private let insertButton = UIButton(type: .system)
  private let trashButton = UIButton(type: .system)
  private let spaceButton = UIButton(type: .system)
  private let backspaceButton = UIButton(type: .system)
  private var currentDraftText = ""
  private var loadedDraftDate: Date?
  private var refreshTimer: Timer?
  private var pendingDraftReset: PendingDraftReset?
  private var pendingProcessingState: Bool?
  private var pendingCommandDate: Date?

  override func viewDidLoad() {
    super.viewDidLoad()
    // Better Voice supplies its own microphone control. This asks iOS to
    // disable the separate system dictation key shown beside custom keyboards.
    hasDictationKey = true
    buildCompactKeyboard()
    refreshTranscript(force: true)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshTranscript(force: false)
    startRefreshing()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    refreshTranscript(force: false)
  }

  private func buildCompactKeyboard() {
    view.backgroundColor = .systemGray6

    let root = UIStackView()
    root.axis = .vertical
    root.spacing = 7
    root.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(root)

    draftView.font = .systemFont(ofSize: 15)
    draftView.textColor = .label
    draftView.backgroundColor = .systemBackground
    draftView.layer.cornerRadius = 10
    draftView.layer.borderWidth = 0.5
    draftView.layer.borderColor = UIColor.separator.cgColor
    draftView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    draftView.autocorrectionType = .yes
    draftView.autocapitalizationType = .sentences
    draftView.returnKeyType = .default
    draftView.isEditable = false
    draftView.isSelectable = true
    draftView.accessibilityLabel = "Better Voice draft"
    root.addArrangedSubview(draftView)
    draftView.heightAnchor.constraint(equalToConstant: 80).isActive = true

    let controls = UIStackView()
    controls.axis = .horizontal
    controls.spacing = 5
    controls.distribution = .fillEqually
    root.addArrangedSubview(controls)

    listeningButton.configuration = compactConfiguration(image: "mic.slash.fill", emphasized: false)
    listeningButton.addTarget(self, action: #selector(toggleProcessing), for: .touchUpInside)
    listeningButton.isEnabled = false
    controls.addArrangedSubview(listeningButton)

    insertButton.configuration = compactConfiguration(image: "text.cursor", emphasized: true)
    insertButton.accessibilityLabel = "Insert Better Voice draft"
    insertButton.addTarget(self, action: #selector(insertDraft), for: .touchUpInside)
    controls.addArrangedSubview(insertButton)

    trashButton.configuration = compactConfiguration(image: "trash", emphasized: false)
    trashButton.accessibilityLabel = "Clear Better Voice draft"
    trashButton.addTarget(self, action: #selector(clearDraft), for: .touchUpInside)
    controls.addArrangedSubview(trashButton)

    spaceButton.configuration = compactConfiguration(image: "space", emphasized: false)
    spaceButton.accessibilityLabel = "Space"
    spaceButton.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
    controls.addArrangedSubview(spaceButton)

    backspaceButton.configuration = compactConfiguration(image: "delete.left", emphasized: false)
    backspaceButton.accessibilityLabel = "Backspace"
    backspaceButton.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)
    controls.addArrangedSubview(backspaceButton)

    controls.heightAnchor.constraint(equalToConstant: 40).isActive = true

    let compactHeight = view.heightAnchor.constraint(equalToConstant: 139)
    compactHeight.priority = UILayoutPriority(999)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
      root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
      compactHeight,
    ])
  }

  private func compactConfiguration(image: String, emphasized: Bool) -> UIButton.Configuration {
    var configuration = emphasized ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
    configuration.image = UIImage(systemName: image)
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 17,
      weight: .semibold
    )
    configuration.cornerStyle = .medium
    configuration.baseBackgroundColor = emphasized
      ? UIColor(red: 0.36, green: 0.42, blue: 0.99, alpha: 1)
      : UIColor.systemGray4
    configuration.baseForegroundColor = emphasized ? .white : .label
    return configuration
  }

  @objc private func deleteBackward() {
    textDocumentProxy.deleteBackward()
  }

  @objc private func insertSpace() {
    textDocumentProxy.insertText(" ")
  }

  @objc private func clearDraft() {
    let liveDraft = SharedTranscriptStore.loadLiveDraft()
    let hasActiveSession = liveDraft?.isListening == true
      && Date().timeIntervalSince(liveDraft?.updatedAt ?? .distantPast) < 3

    SharedTranscriptStore.clearCommittedTranscript()
    if hasActiveSession {
      SharedTranscriptStore.postKeyboardCommand(.clearDraft)
      pendingDraftReset = .clear
      listeningButton.isEnabled = false
    } else {
      SharedTranscriptStore.clearLiveDraft()
      pendingDraftReset = nil
    }

    displayDraft("", heard: "")
    loadedDraftDate = nil
    insertButton.isEnabled = false
    trashButton.isEnabled = false
  }

  @objc private func toggleProcessing() {
    guard
      hasFullAccess,
      let liveDraft = SharedTranscriptStore.loadLiveDraft(),
      liveDraft.isListening,
      liveDraft.canGateProcessing,
      Date().timeIntervalSince(liveDraft.updatedAt) < 3
    else {
      return
    }

    let isProcessing = pendingProcessingState ?? liveDraft.processingEnabled
    let nextState = !isProcessing
    pendingProcessingState = nextState
    pendingCommandDate = Date()
    SharedTranscriptStore.postKeyboardCommand(nextState ? .startProcessing : .stopProcessing)
    configureListeningButton(active: true, processing: nextState, supportsGating: true)
  }

  @objc private func insertDraft() {
    let draft = currentDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !draft.isEmpty else { return }
    textDocumentProxy.insertText(draft)
    if let liveDraft = SharedTranscriptStore.loadLiveDraft(),
       liveDraft.isListening,
      Date().timeIntervalSince(liveDraft.updatedAt) < 3 {
      SharedTranscriptStore.postKeyboardCommand(.finishDraft)
      pendingDraftReset = .finish
      pendingProcessingState = false
      pendingCommandDate = Date()
      displayDraft("", heard: "")
      loadedDraftDate = nil
      insertButton.isEnabled = false
      configureListeningButton(active: true, processing: false, supportsGating: liveDraft.canGateProcessing)
      listeningButton.isEnabled = false
      trashButton.isEnabled = false
    }
  }

  private func refreshTranscript(force: Bool) {
    guard hasFullAccess else {
      displayDraft("", heard: "")
      configureListeningButton(active: false, processing: false, supportsGating: false)
      insertButton.isEnabled = false
      trashButton.isEnabled = false
      return
    }

    let liveDraft = SharedTranscriptStore.loadLiveDraft()
    let committed = SharedTranscriptStore.load()

    if let liveDraft,
       liveDraft.isListening,
       Date().timeIntervalSince(liveDraft.updatedAt) < 3 {
      if let pendingDraftReset {
        let textWasCleared = liveDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && liveDraft.rawHeardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let resetFinished = textWasCleared
          && (pendingDraftReset == .clear || !liveDraft.processingEnabled)
        if resetFinished {
          self.pendingDraftReset = nil
        } else {
          insertButton.isEnabled = false
          trashButton.isEnabled = false
          listeningButton.isEnabled = false
          return
        }
      }
      if force || loadedDraftDate != liveDraft.updatedAt {
        displayDraft(liveDraft.text, heard: liveDraft.rawHeardText)
        loadedDraftDate = liveDraft.updatedAt
      }

      var processing = liveDraft.processingEnabled
      if let pendingProcessingState, let pendingCommandDate,
         Date().timeIntervalSince(pendingCommandDate) < 1.5 {
        if liveDraft.processingEnabled == pendingProcessingState {
          self.pendingProcessingState = nil
          self.pendingCommandDate = nil
        } else {
          processing = pendingProcessingState
        }
      } else {
        pendingProcessingState = nil
        pendingCommandDate = nil
      }
      configureListeningButton(
        active: true,
        processing: processing,
        supportsGating: liveDraft.canGateProcessing
      )
      insertButton.isEnabled = !liveDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      trashButton.isEnabled = !liveDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !liveDraft.rawHeardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return
    }

    let latestText: String
    let latestDate: Date
    if let liveDraft, let committed {
      if liveDraft.updatedAt > committed.committedAt {
        latestText = liveDraft.text
        latestDate = liveDraft.updatedAt
      } else {
        latestText = committed.text
        latestDate = committed.committedAt
      }
    } else if let liveDraft {
      latestText = liveDraft.text
      latestDate = liveDraft.updatedAt
    } else if let committed {
      latestText = committed.text
      latestDate = committed.committedAt
    } else {
      displayDraft("", heard: "")
      configureListeningButton(active: false, processing: false, supportsGating: false)
      insertButton.isEnabled = false
      trashButton.isEnabled = false
      return
    }

    if force || loadedDraftDate != latestDate {
      displayDraft(latestText, heard: "")
      loadedDraftDate = latestDate
    }
    configureListeningButton(active: false, processing: false, supportsGating: false)
    insertButton.isEnabled = !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    trashButton.isEnabled = !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func displayDraft(_ text: String, heard: String) {
    currentDraftText = text
    let attributed = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: UIFont.systemFont(ofSize: 15),
        .foregroundColor: UIColor.label,
      ]
    )
    let trimmedHeard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedHeard.isEmpty {
      if !text.isEmpty { attributed.append(NSAttributedString(string: "\n")) }
      attributed.append(
        NSAttributedString(
          string: trimmedHeard,
          attributes: [
            .font: UIFont.italicSystemFont(ofSize: 15),
            .foregroundColor: UIColor.secondaryLabel,
          ]
        )
      )
    }
    draftView.attributedText = attributed
    draftView.accessibilityValue = [text, trimmedHeard].filter { !$0.isEmpty }.joined(separator: ", heard: ")
  }

  private func configureListeningButton(active: Bool, processing: Bool, supportsGating: Bool) {
    let image: String
    if active, supportsGating {
      image = processing ? "stop.fill" : "mic.fill"
    } else if active {
      image = "waveform"
    } else {
      image = "mic.slash.fill"
    }

    listeningButton.configuration = compactConfiguration(image: image, emphasized: false)
    if active, processing {
      listeningButton.configuration?.baseForegroundColor = .systemRed
    }
    listeningButton.isEnabled = active && supportsGating
    listeningButton.accessibilityLabel = processing ? "Pause Better Voice listening" : "Start Better Voice listening"
  }

  private func startRefreshing() {
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
      self?.refreshTranscript(force: false)
    }
  }
}
