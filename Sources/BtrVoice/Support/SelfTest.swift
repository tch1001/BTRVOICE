import CoreAudio
import CoreGraphics
import Foundation

/// `BtrVoice --self-test` exercises the parts that don't need a microphone, a screen,
/// or TCC permission: command parsing, buffer arithmetic, and event chunking.
/// Run it after changing any of those; the injection path itself can only be verified
/// interactively, since posting key events requires Accessibility access.
enum SelfTest {

    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
            if condition() {
                print("  ok   \(name)")
            } else {
                failures += 1
                let extra = detail()
                print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
            }
        }


        print("VoiceCommands")
        do {
            let actions = VoiceCommands.parse("hello world do paste goodbye", enabled: true)
            check("splits literals around a command",
                  actions == [.insert("hello world"), .pasteInTarget, .insert("goodbye")],
                  "\(actions)")
        }
        do {
            let actions = VoiceCommands.parse("hello do paste there", enabled: false)
            check("passes everything through when disabled",
                  actions == [.insert("hello do paste there")], "\(actions)")
        }
        do {
            // The recogniser punctuates and capitalises; commands must survive that.
            let actions = VoiceCommands.parse("Do paste.", enabled: true)
            check("matches despite capitalisation and punctuation",
                  actions == [.pasteInTarget], "\(actions)")
        }
        do {
            check("do paste presses ⌘V", VoiceCommands.parse("do paste", enabled: true) == [.pasteInTarget])
            check("do copy presses ⌘C", VoiceCommands.parse("do copy", enabled: true) == [.copyInTarget])
            check("do select all presses ⌘A", VoiceCommands.parse("do select all", enabled: true) == [.selectAllInTarget])
            check("do click clicks", VoiceCommands.parse("do click", enabled: true) == [.clickAtPointer])
            check("go here presses F12", VoiceCommands.parse("go here", enabled: true) == [.jumpToReferences])
            check("go here tolerates recognition punctuation", VoiceCommands.parse("Go here.", enabled: true) == [.jumpToReferences])
            check("go here stays guarded inside prose", VoiceCommands.parse("please go here now", enabled: true) == [.insert("please go here now")])
            check("go here never waits for confirmation",
                  !DictationController.voiceCommandNeedsConfirmation(
                      .jumpToReferences, runImmediately: false
                  ))
            check("immediate command setting skips confirmation",
                  !DictationController.voiceCommandNeedsConfirmation(
                      .commitAndSend, runImmediately: true
                  ))
            check("disabling immediate commands restores confirmation",
                  DictationController.voiceCommandNeedsConfirmation(
                      .commitAndSend, runImmediately: false
                  ))
            check("do insert commits", VoiceCommands.parse("do insert", enabled: true) == [.commit])
            check("do send it inserts and sends", VoiceCommands.parse("do send it", enabled: true) == [.commitAndSend])
            check("insert waits for finalized buffer", BufferAction.commit.requiresFinalizedBuffer)
            check("send waits for finalized buffer", BufferAction.commitAndSend.requiresFinalizedBuffer)
            check("non-insert command does not wait for buffer", !BufferAction.pasteInTarget.requiresFinalizedBuffer)
        }
        do {
            let (text, actions) = VoiceCommands.extractEditorCommands("hello world [[cmd:send]]")
            check("editor marker extracted", text == "hello world" && actions == [.commitAndSend],
                  "\(text) \(actions)")
            let (text2, actions2) = VoiceCommands.extractEditorCommands("just prose, no markers")
            check("no markers passes through", text2 == "just prose, no markers" && actions2.isEmpty)
            let (text3, actions3) = VoiceCommands.extractEditorCommands("[[cmd:paste]]")
            check("bare marker leaves empty text", text3.isEmpty && actions3 == [.pasteInTarget])
            let (text4, actions4) = VoiceCommands.extractEditorCommands("[[cmd:references]]")
            check("go here editor marker presses F12", text4.isEmpty && actions4 == [.jumpToReferences])
            let (text5, _) = VoiceCommands.extractEditorCommands("keep this [[unknown junk]] clean")
            check("unknown bracket junk is stripped", text5 == "keep this clean", text5)
        }
        do {
            let combo = TextInjector.parseCombo("cmd+shift+p")
            check("cmd+shift+p parses", combo?.key == 35 && combo?.display == "⇧⌘P",
                  "\(String(describing: combo))")
            check("bare key parses", TextInjector.parseCombo("escape")?.display == "Escape")
            check("F12 parses", TextInjector.parseCombo("f12")?.key == TextInjector.f12KeyCode)
            check("space separators work", TextInjector.parseCombo("ctrl c")?.display == "⌃C")
            check("unknown key rejected", TextInjector.parseCombo("cmd+banana") == nil)
            check("two plain keys rejected", TextInjector.parseCombo("a+b") == nil)
            check("modifier only rejected", TextInjector.parseCombo("cmd+shift") == nil)
        }

        do {
            check("command words without the trigger stay literal",
                  VoiceCommands.parse("please paste the text", enabled: true)
                  == [.insert("please paste the text")])
            check("bare trigger stays literal",
                  VoiceCommands.parse("what should I do", enabled: true)
                  == [.insert("what should I do")])
            check("trigger followed by a non-command stays literal",
                  VoiceCommands.parse("do the dishes", enabled: true)
                  == [.insert("do the dishes")])
        }
        do {
            let actions = VoiceCommands.parse("", enabled: true)
            check("empty input yields nothing", actions.isEmpty, "\(actions)")
        }

        print("VirtualKeyboard")
        do {
            let merged = StickyModifierPointerBridge.mergedFlags(
                eventFlags: [.maskControl],
                activeModifiers: [.maskShift, .maskCommand]
            )
            check("latched Shift is added to a real pointer event",
                  merged.contains(.maskShift))
            check("multiple virtual modifiers can accompany a pointer event",
                  merged.contains(.maskCommand))
            check("physical pointer modifiers are preserved",
                  merged.contains(.maskControl))
            check("drag and scroll events participate in sticky modifiers",
                  StickyModifierPointerBridge.pointerEventTypes.contains(.leftMouseDragged)
                    && StickyModifierPointerBridge.pointerEventTypes.contains(.scrollWheel))
            check("the keyboard panel is non-activating from construction",
                  VirtualKeyboardPanelPolicy.styleMask.contains(.nonactivatingPanel))
            check("virtual keys post into the current login session",
                  TextInjector.virtualKeyboardSourceState == .combinedSessionState)

        }

        print("DesktopVoice")
        do {
            let brave = DesktopVoiceApplicationTarget(
                displayName: "Brave Browser",
                bundleIdentifier: "com.brave.Browser",
                applicationURL: URL(fileURLWithPath: "/Applications/Brave Browser.app")
            )
            let telegram = DesktopVoiceApplicationTarget(
                displayName: "Telegram",
                bundleIdentifier: "ru.keepcoder.Telegram",
                applicationURL: URL(fileURLWithPath: "/Applications/Telegram.app")
            )
            let resolveApplication: DesktopVoiceCommandRouter.ApplicationResolver = { name in
                switch name {
                case "browser", "brave": return brave
                case "telegram": return telegram
                default: return nil
                }
            }
            let router = DesktopVoiceCommandRouter(resolveApplication: resolveApplication)

            check(
                "semantic browser alias resolves to the preferred application",
                router.route("Open the browser.") == .plan(DesktopVoicePlan(
                    summary: "Open Brave Browser",
                    actions: [.openApplication(brave)]
                ))
            )
            check(
                "a compound browser command becomes an ordered local plan",
                router.route("Open a browser and create a new tab") == .plan(DesktopVoicePlan(
                    summary: "Open Brave Browser and create a new tab",
                    actions: [.openApplication(brave), .pressShortcut("cmd+t")]
                ))
            )
            check(
                "an explicitly named application launches through the same route",
                router.route("Launch Telegram") == .plan(DesktopVoicePlan(
                    summary: "Open Telegram",
                    actions: [.openApplication(telegram)]
                ))
            )
            check(
                "a browser shortcut does not require an application launch",
                router.route("Open a new tab") == .plan(DesktopVoicePlan(
                    summary: "Create a new tab",
                    actions: [.pressShortcut("cmd+t")]
                ))
            )
            if case .unsupported = router.route("Arrange my research workspace") {
                check("unknown goals stay out of the deterministic fast path", true)
            } else {
                check("unknown goals stay out of the deterministic fast path", false)
            }
            let fastPathIDs = DesktopVoiceCommandRouter.fastPaths.map(\.id)
            check("the introspectable command registry has seven fast paths",
                  fastPathIDs.count == 7)
            check("fast path registry identifiers are unique",
                  Set(fastPathIDs).count == fastPathIDs.count)
            if case .answer(let answer) = router.route("What fast path commands do you have?") {
                check("voice control can list its own commands",
                      answer.contains("7 local fast paths")
                        && answer.contains("Create a new tab")
                        && answer.contains("Open a new tab"),
                      answer)
            } else {
                check("voice control can list its own commands", false)
            }
            check("voice control explains how its fast paths are extended",
                  router.route("How do I add a new fast path command?")
                    == .answer(DesktopVoiceCommandRouter.addingFastPathsAnswer))

            for question in ["Read my screen!", "Can you read my screen?", "What am I looking at?"] {
                check("a spoken screen question requests a fresh capture: \(question)",
                      router.route(question) == .readScreen)
            }

            let learnedSkill = DesktopVoiceLearnedSkill(
                id: UUID(),
                name: "Rescue tab",
                triggers: ["rescue tab"],
                summary: "Reopen the last closed tab",
                actions: [DesktopVoiceSkillActionSpec(kind: .shortcut, value: "cmd+shift+t")],
                createdAt: Date(),
                updatedAt: Date()
            )
            let learnedRouter = DesktopVoiceCommandRouter(
                resolveApplication: resolveApplication,
                learnedSkills: { [learnedSkill] }
            )
            check(
                "a learned exact phrase becomes a deterministic local plan",
                learnedRouter.route("Rescue tab!") == .plan(DesktopVoicePlan(
                    summary: "Reopen the last closed tab",
                    actions: [.pressShortcut("cmd+shift+t")]
                ))
            )
            if case .answer(let answer) = learnedRouter.route("List fast paths") {
                check("learned skills appear in voice introspection",
                      answer.contains("1 learned fast path") && answer.contains("Rescue tab"), answer)
            } else {
                check("learned skills appear in voice introspection", false)
            }

            let answerBody: [String: Any] = [
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "Hard Submit sends the current command immediately.",
                    ]],
                ]] as [[String: Any]],
            ]
            let answerDecision = try? DesktopVoiceAssistant.interpret(
                answerBody,
                resolveApplication: resolveApplication
            )
            check("the slow path reads conversational answers",
                  answerDecision == .answer("Hard Submit sends the current command immediately."))

            let screenCall: [String: Any] = ["output": [[
                "type": "function_call", "name": "read_current_screen", "arguments": "{}",
            ]]]
            check("the model can request screen reading without a desktop action",
                  (try? DesktopVoiceAssistant.interpret(screenCall, resolveApplication: resolveApplication)) == .readScreen)
            let invalidScreenCall: [String: Any] = ["output": [[
                "type": "function_call", "name": "read_current_screen", "arguments": "{\"action\":\"click\"}",
            ]]]
            check("a screen request cannot smuggle in an action",
                  (try? DesktopVoiceAssistant.interpret(invalidScreenCall, resolveApplication: resolveApplication)) == nil)

            let context = DesktopVoiceAssistant.Context(targetName: "Brave", recentActivity: [])
            let ordinaryRequest = DesktopVoiceAssistant.requestBody(
                utterance: "Open Brave", context: context, screen: nil, learnedSkills: []
            )
            check("ordinary commands retain text input and existing action tools",
                  ordinaryRequest["input"] is String
                    && ((ordinaryRequest["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "run_desktop_plan" } == true))
            let snapshot = DesktopScreenSnapshot(jpeg: Data([1, 2, 3]), width: 1600, height: 900,
                                                 displayID: 1, application: "Brave", capturedAt: Date())
            let screenRequest = DesktopVoiceAssistant.requestBody(
                utterance: "Explain this error", context: context, screen: snapshot, learnedSkills: []
            )
            let screenInput = screenRequest["input"] as? [[String: Any]]
            let screenContent = screenInput?.last?["content"] as? [[String: Any]]
            check("the vision model receives image bytes as an image rather than tool-output text",
                  screenContent?.last?["type"] as? String == "input_image"
                    && screenContent?.last?["image_url"] as? String == "data:image/jpeg;base64,AQID")
            check("screen interpretation cannot execute actions or save skills",
                  (screenRequest["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["inspect_ui", "wait_ui"]
                    && screenRequest["tool_choice"] as? String == "auto"
                    && screenRequest["store"] as? Bool == false)
            check("ordinary requests and vision requests both encode as valid JSON",
                  JSONSerialization.isValidJSONObject(ordinaryRequest) && JSONSerialization.isValidJSONObject(screenRequest))
            var accessibleSnapshot = DesktopScreenSnapshot(jpeg: nil, width: 0, height: 0,
                displayID: 0, application: "Brave", capturedAt: Date())
            accessibleSnapshot.accessibility = DesktopAccessibilityContext(
                text: "AXButton: Save | available actions: AXPress", elementCount: 1, truncated: false)
            let accessibleRequest = DesktopVoiceAssistant.requestBody(
                utterance: "Which buttons are here?", context: context, screen: accessibleSnapshot, learnedSkills: [])
            let accessibleInput = accessibleRequest["input"] as? [[String: Any]]
            let accessibleContent = accessibleInput?.last?["content"] as? [[String: Any]]
            check("structured screen questions send labels before any image bytes",
                  accessibleContent?.count == 1
                    && (accessibleContent?.first?["text"] as? String)?.contains("AXButton: Save") == true)
            check("structured reading may inspect more UI or request an image without action tools",
                  (accessibleRequest["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["inspect_ui", "wait_ui", "read_screen_image"])
            accessibleSnapshot.imageUnavailable = "Screen Recording access is required."
            let deniedImageRequest = DesktopVoiceAssistant.requestBody(
                utterance: "Describe this chart", context: context, screen: accessibleSnapshot, learnedSkills: [])
            check("a denied image cannot cause a repeated screenshot request loop",
                  (deniedImageRequest["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["inspect_ui", "wait_ui"])
            let button = DesktopAccessibilityReader.describe(role: "AXButton", label: "Save", value: nil,
                actions: ["AXPress"], enabled: false, secure: false)
            check("accessibility preserves a button's exact label, action, and disabled state",
                  button.contains("Save") && button.contains("AXPress") && button.contains("disabled"))
            let password = DesktopAccessibilityReader.describe(role: "AXTextField", label: "secret-label",
                value: "secret-value", actions: [], enabled: true, secure: true)
            check("protected accessibility fields never expose their label or value",
                  !password.contains("secret-label") && !password.contains("secret-value"))
            let monitors = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                            CGRect(x: -1920, y: -1080, width: 1920, height: 1080)]
            check("screen capture follows the active window onto a display with negative coordinates",
                  DesktopScreenReader.displayIndex(frames: monitors,
                    window: CGRect(x: -1800, y: -1000, width: 1000, height: 800), mainIndex: 0) == 1)
            check("an unavailable window falls back to the main display",
                  DesktopScreenReader.displayIndex(frames: monitors, window: nil, mainIndex: 0) == 0)
            check("headless screen capture has no target",
                  DesktopScreenReader.displayIndex(frames: [], window: nil, mainIndex: 0) == nil)
            let boundedImage = DesktopScreenReader.imageSize(width: 7680, height: 4320)
            check("large displays keep their aspect ratio within the image budget",
                  boundedImage.width == 2560 && boundedImage.height == 1440)

            let planBody: [String: Any] = [
                "output": [[
                    "type": "function_call",
                    "name": "run_desktop_plan",
                    "arguments": """
                    {"summary":"Open Brave and create a tab","actions":[
                      {"type":"open_application","application":"brave","shortcut":null},
                      {"type":"shortcut","application":null,"shortcut":"cmd+t"}
                    ]}
                    """,
                ]] as [[String: Any]],
            ]
            let planDecision = try? DesktopVoiceAssistant.interpret(
                planBody,
                resolveApplication: resolveApplication
            )
            check("the slow path compiles model tool calls into typed actions",
                  planDecision == .plan(DesktopVoicePlan(
                    summary: "Open Brave and create a tab",
                    actions: [.openApplication(brave), .pressShortcut("cmd+t")]
                  )))

            let unsafeBody: [String: Any] = [
                "output": [[
                    "type": "function_call",
                    "name": "run_desktop_plan",
                    "arguments": """
                    {"summary":"Run an unsafe shortcut","actions":[
                      {"type":"shortcut","application":null,"shortcut":"cmd+banana"}
                    ]}
                    """,
                ]] as [[String: Any]],
            ]
            check("the slow path rejects shortcuts outside its allowlist",
                  (try? DesktopVoiceAssistant.interpret(
                    unsafeBody,
                    resolveApplication: resolveApplication
                  )) == nil)

            let teachBody: [String: Any] = [
                "output": [[
                    "type": "function_call",
                    "name": "teach_fast_path",
                    "arguments": """
                    {"name":"Rescue tab","triggers":["rescue tab"],
                     "summary":"Reopen the last closed tab","actions":[
                      {"type":"shortcut","application":null,"shortcut":"cmd+shift+t"}
                    ]}
                    """,
                ]] as [[String: Any]],
            ]
            let teachDecision = try? DesktopVoiceAssistant.interpret(
                teachBody,
                resolveApplication: resolveApplication
            )
            check(
                "the slow path compiles an explicit teaching call into a declarative skill",
                teachDecision == .learn(DesktopVoiceSkillDraft(
                    name: "Rescue tab",
                    triggers: ["rescue tab"],
                    summary: "Reopen the last closed tab",
                    actions: [DesktopVoiceSkillActionSpec(kind: .shortcut, value: "cmd+shift+t")]
                ))
            )

            let skillsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("btrvoice-self-test-\(UUID().uuidString).json")
            let skillStore = DesktopVoiceSkillStore(fileURL: skillsURL)
            _ = try? skillStore.add(
                DesktopVoiceSkillDraft(
                    name: "Rescue tab",
                    triggers: ["rescue tab", "bring back tab"],
                    summary: "Reopen the last closed tab",
                    actions: [DesktopVoiceSkillActionSpec(kind: .shortcut, value: "cmd+shift+t")]
                ),
                resolveApplication: resolveApplication
            )
            let reloadedSkills = DesktopVoiceSkillStore(fileURL: skillsURL).skills
            check("learned skills survive a store reload",
                  reloadedSkills.count == 1 && reloadedSkills[0].triggers.contains("rescue tab"))
            try? FileManager.default.removeItem(at: skillsURL)
        }

        DesktopAccessibilitySelfTest.run { check($0, $1) }
        DesktopReadingSelfTest.pure { check($0, $1) }

        print("Inputs")
        do {
            let source = AudioInputSourceID.microphone(uid: "USB microphone 1")
            check("microphone source IDs preserve the device UID",
                  AudioInputSourceID.microphoneUID(from: source) == "USB microphone 1", source)
            check("system default is distinct from a pinned microphone",
                  AudioInputSourceID.microphoneUID(from: AudioInputSourceID.systemDefault) == nil)
        }

        print("Jarvis")
        do {
            let bundle = URL(fileURLWithPath: "/Users/example/btr_voice/build/BtrVoice.app")
            let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
            let expected = "/Users/example/jarvis/plugins/jarvis/voice/__main__.py"
            let plugins = JarvisVoiceInstallation.findPlugins(
                environment: [:], bundleURL: bundle, homeDirectory: home,
                fileExists: { $0 == expected }
            )
            check("Start Jarvis finds a sibling voice provider",
                  plugins?.path == "/Users/example/jarvis/plugins", plugins?.path ?? "nil")

            let configured = JarvisVoiceInstallation.findPlugins(
                environment: ["JARVIS_PLUGIN_DIR": "/opt/jarvis/plugins"],
                bundleURL: bundle, homeDirectory: home,
                fileExists: { $0 == "/opt/jarvis/plugins/jarvis/voice/__main__.py" }
            )
            check("Start Jarvis honors an explicit plugin directory",
                  configured?.path == "/opt/jarvis/plugins", configured?.path ?? "nil")
        }
        do {
            let plugins = URL(fileURLWithPath: "/opt/jarvis/plugins", isDirectory: true)
            let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
            let python = JarvisVoiceInstallation.findPython(
                environment: [:], pluginsDirectory: plugins, homeDirectory: home,
                isExecutable: { $0 == "/opt/jarvis/plugins/.venv/bin/python" }
            )
            check("Start Jarvis prefers its project Python",
                  python?.path == "/opt/jarvis/plugins/.venv/bin/python", python?.path ?? "nil")
        }
        do {
            check("jarvis gets the whole utterance verbatim",
                  VoiceCommands.parse("Hey Jarvis, clean this up", enabled: true)
                  == [.jarvis("Hey Jarvis, clean this up")])
            check("text before the wake word is part of the utterance",
                  VoiceCommands.parse("hello world jarvis fix the last sentence", enabled: true)
                  == [.jarvis("hello world jarvis fix the last sentence")])
            check("bare jarvis with nothing after it stays literal",
                  VoiceCommands.parse("Jarvis.", enabled: true) == [.insert("Jarvis.")])
            check("jarvis utterance keeps command words verbatim",
                  VoiceCommands.parse("jarvis remember do paste means control v", enabled: true)
                  == [.jarvis("jarvis remember do paste means control v")])
        }
        do {
            let ownerOnly = SpeakerFrameGate.classify(
                predictions: [0.82, 0.03, 0.02, 0.01],
                speakerCount: 4,
                ownerIndex: 0
            )
            check("owner-only speaker frames pass the local voice gate",
                  ownerOnly.mask == [true] && !ownerOnly.overlap)

            let anotherSpeaker = SpeakerFrameGate.classify(
                predictions: [0.04, 0.88, 0.02, 0.01],
                speakerCount: 4,
                ownerIndex: 0
            )
            check("another speaker is withheld before Realtime",
                  anotherSpeaker.mask == [false] && !anotherSpeaker.overlap)

            let overlapping = SpeakerFrameGate.classify(
                predictions: [0.83, 0.76, 0.02, 0.01],
                speakerCount: 4,
                ownerIndex: 0
            )
            check("overlapping speakers are withheld rather than guessed",
                  overlapping.mask == [false] && overlapping.overlap)
        }
        do {
            let samples = Data([0x10, 0x27, 0xf0, 0xd8, 0x20, 0x4e, 0xe0, 0xb1])
            let accepted = JarvisPCMFrameMask.apply(
                pcm16: samples,
                mask: [true],
                frameDurationMilliseconds: 80,
                sampleRate: 50
            )
            check("native owner mask forwards a non-empty PCM window", !accepted.isEmpty)
            let missingDecision = JarvisPCMFrameMask.apply(
                    pcm16: samples,
                    mask: [],
                    frameDurationMilliseconds: 80,
                    sampleRate: 50
                  )
            check("native empty speaker decisions fail closed to timed silence",
                  missingDecision.count == samples.count && missingDecision.allSatisfy { $0 == 0 })
            let rejected = JarvisPCMFrameMask.apply(
                    pcm16: samples,
                    mask: [false],
                    frameDurationMilliseconds: 80,
                    sampleRate: 50
                  )
            check("native rejected speakers become silence before Realtime",
                  rejected.count == samples.count && rejected.allSatisfy { $0 == 0 })
        }
        do {
            let builtInMic = JarvisAudioDevice(
                objectID: 1, uid: "builtin-mic", name: "Mac microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                inputChannels: 1, outputChannels: 0, relatedDeviceIDs: [],
                isDefaultInput: false, isDefaultOutput: false
            )
            let builtInSpeakers = JarvisAudioDevice(
                objectID: 2, uid: "builtin-output", name: "Mac speakers",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                inputChannels: 0, outputChannels: 2, relatedDeviceIDs: [],
                isDefaultInput: false, isDefaultOutput: true
            )
            let usbInterface = JarvisAudioDevice(
                objectID: 3, uid: "usb-duplex", name: "USB interface",
                transportType: kAudioDeviceTransportTypeUSB,
                inputChannels: 2, outputChannels: 2, relatedDeviceIDs: [],
                isDefaultInput: true, isDefaultOutput: false
            )
            check("a duplex audio device is an echo-cancellation pair",
                  JarvisAudioDeviceCatalog.likelySupportsEchoCancellation(
                    input: usbInterface, output: usbInterface
                  ))
            check("the built-in microphone and speakers are an echo-cancellation pair",
                  JarvisAudioDeviceCatalog.likelySupportsEchoCancellation(
                    input: builtInMic, output: builtInSpeakers
                  ))
            check("an app-only device selection does not start the system voice processor",
                  !JarvisAudioDeviceCatalog.supportsSystemVoiceProcessing(
                    input: builtInMic, output: builtInSpeakers
                  ))
            let defaultBuiltInMic = JarvisAudioDevice(
                objectID: 1, uid: "builtin-mic", name: "Mac microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                inputChannels: 1, outputChannels: 0, relatedDeviceIDs: [],
                isDefaultInput: true, isDefaultOutput: false
            )
            check("the compatible macOS default pair starts the system voice processor",
                  JarvisAudioDeviceCatalog.supportsSystemVoiceProcessing(
                    input: defaultBuiltInMic, output: builtInSpeakers
                  ))
            check("an unrelated USB microphone and built-in speakers need guidance",
                  !JarvisAudioDeviceCatalog.likelySupportsEchoCancellation(
                    input: usbInterface, output: builtInSpeakers
                  ))
            check("the route helper recommends a microphone paired with the speakers",
                  JarvisAudioDeviceCatalog.recommendedInput(
                    for: builtInSpeakers,
                    among: [usbInterface, builtInMic]
                  ) == builtInMic)
            let liveCatalog = JarvisAudioDeviceCatalog.snapshot()
            check("native audio discovery separates input and output devices",
                  liveCatalog.inputs.allSatisfy(\.hasInput)
                    && liveCatalog.outputs.allSatisfy(\.hasOutput))
        }
        do {
            check("remember is classified as a note",
                  JarvisEngine.classify("Hey Jarvis, remember that github dot com means tch1001.github.io")
                  == .remember("github dot com means tch1001.github.io"))
            check("remember drops the filler word to",
                  JarvisEngine.classify("jarvis remember to spell my name as Fish")
                  == .remember("spell my name as Fish"))
            check("everything else is an edit with the full utterance",
                  JarvisEngine.classify("Jarvis, replace github dot com with the real URL")
                  == .edit("Jarvis, replace github dot com with the real URL"))
        }
        do {
            check("sanitize strips echoed tags and newlines",
                  JarvisEngine.sanitize("<text>\nhello\nworld\n</text>") == "hello world")
            check("sanitize collapses whitespace runs",
                  JarvisEngine.sanitize("  a   b\t\tc \n d ") == "a b c d")
            check("sanitize keeps math comparisons intact",
                  JarvisEngine.sanitize("x < 3 and y > 5") == "x < 3 and y > 5")
            check("sanitize leaves clean text alone",
                  JarvisEngine.sanitize("already clean") == "already clean")
        }
        do {
            // Assistant chatter would otherwise be typed as if the user said it.
            check("polish strips an acknowledgement preamble",
                  JarvisEngine.sanitize("Sure, here's the edited text: meet me at six")
                  == "meet me at six")
            check("polish strips a first-person preamble",
                  JarvisEngine.sanitize("I've updated the transcript: meet me at six")
                  == "meet me at six")
            check("polish strips a trailing offer of help",
                  JarvisEngine.sanitize("meet me at six. Let me know if you'd like changes.")
                  == "meet me at six.")
            check("polish strips code fences",
                  JarvisEngine.sanitize("```text meet me at six ```") == "meet me at six")
            check("polish unwraps a fully quoted reply",
                  JarvisEngine.sanitize("\"meet me at six\"") == "meet me at six")

            // Conservative by design: dictated speech that merely resembles
            // preamble must survive untouched.
            check("polish keeps a dictated colon sentence",
                  JarvisEngine.sanitize("shopping list: eggs and milk")
                  == "shopping list: eggs and milk")
            check("polish keeps a dictated Sure opener",
                  JarvisEngine.sanitize("Sure, I'll be there at six")
                  == "Sure, I'll be there at six")
            check("polish keeps inner quotes",
                  JarvisEngine.sanitize("he said \"yes\" and left")
                  == "he said \"yes\" and left")
            check("polish never strips the reply to nothing",
                  JarvisEngine.sanitize("Here's the edited text:")
                  == "Here's the edited text:")

            // Regression: an offer-shaped phrase mid-sentence is the user's own
            // speech and must survive. This once truncated dictation to its head.
            check("polish keeps a dictated feel-free clause",
                  JarvisEngine.sanitize("For BtrVoice, feel free to add a setting for this")
                  == "For BtrVoice, feel free to add a setting for this")
            check("polish keeps a dictated let-me-know clause",
                  JarvisEngine.sanitize("Ask him and let me know if he agrees")
                  == "Ask him and let me know if he agrees")
            check("polish keeps a dictated would-you-like clause",
                  JarvisEngine.sanitize("Tell me would you like me to come along")
                  == "Tell me would you like me to come along")
            check("polish still strips a sign-off after a full stop",
                  JarvisEngine.sanitize("Meet me at six. Let me know if that works.")
                  == "Meet me at six.")
        }
        do {
            // Extras cost a ⌘C or expose the clipboard, so they are opt-in per
            // utterance rather than gathered every time.
            check("selection is requested by highlight wording",
                  JarvisEngine.wants(.selection, in: "Jarvis, summarise what I highlighted"))
            check("selection is requested by selected wording",
                  JarvisEngine.wants(.selection, in: "Jarvis, translate the selected text"))
            check("clipboard is requested by clipboard wording",
                  JarvisEngine.wants(.clipboard, in: "Jarvis, paste in what's on my clipboard"))
            check("a plain edit asks for neither",
                  !JarvisEngine.wants(.selection, in: "Jarvis, make that more formal")
                  && !JarvisEngine.wants(.clipboard, in: "Jarvis, make that more formal"))
        }

        failures += StreamingEditorSelfTest.run()

        print("TextBuffer")
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Hello there.")])
            buffer.apply([.insert("How are you?")])
            check("inserts a separating space",
                  buffer.committedText == "Hello there. How are you?", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Line one"), .insert("\n"), .insert("Line two")])
            check("no space around newlines",
                  buffer.committedText == "Line one\nLine two", buffer.committedText.debugDescription)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Wait")])
            buffer.apply([.insert(", actually")])
            check("no space before punctuation",
                  buffer.committedText == "Wait, actually", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("alpha beta gamma")])
            buffer.deleteLastWord()
            check("delete word drops one word",
                  buffer.committedText == "alpha beta ", buffer.committedText.debugDescription)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("something")])
            buffer.clear()
            check("clear empties the buffer", buffer.committedText.isEmpty)
            buffer.undo()
            check("undo restores the cleared text",
                  buffer.committedText == "something", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Committed.")])
            buffer.setPartial("in flight")
            check("display text includes the live partial",
                  buffer.displayText == "Committed. in flight", buffer.displayText)
            check("committed text excludes the live partial",
                  buffer.committedText == "Committed.", buffer.committedText)
            buffer.setReplacementPreview("unfinished editor rewrite")
            check("committed text excludes the editor preview",
                  buffer.committedText == "Committed.", buffer.committedText)
            check("editor preview is unconfirmed", buffer.hasUnconfirmedText)
            buffer.setReplacementPreview(nil)
            let escalated = buffer.apply([.pasteInTarget])
            check("commands are escalated to the controller", escalated == [.pasteInTarget], "\(escalated)")
            check("finalising clears the partial", buffer.partial.isEmpty)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("confirmed words")])
            buffer.setPartial("still in flight")
            buffer.clearCommitted()
            check("clearCommitted drops confirmed text only",
                  buffer.committedText.isEmpty && buffer.partial == "still in flight",
                  "\(buffer.committedText.debugDescription) / \(buffer.partial)")
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("hi 👍🏽")])
            buffer.deleteLastCharacter()
            check("backspace removes a whole emoji", buffer.committedText == "hi ", buffer.committedText.debugDescription)
            buffer.deleteLastCharacter()
            buffer.deleteLastCharacter()
            buffer.deleteLastCharacter()
            check("backspace stops at empty", buffer.committedText.isEmpty)
            buffer.deleteLastCharacter() // must not crash on empty
            buffer.undo()
            check("backspace is undoable", buffer.committedText == "h", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("alpha beta")])
            buffer.deleteLastWord()
            check("backspace ⌥ variant drops the last word",
                  buffer.committedText == "alpha ", buffer.committedText.debugDescription)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Already committed.")])
            buffer.setPartial("still in flight")
            buffer.flushPartial()
            check("flushPartial promotes the live tail",
                  buffer.committedText == "Already committed. still in flight", buffer.committedText)
            check("flushPartial empties the partial", buffer.partial.isEmpty)
            buffer.flushPartial()
            check("flushPartial is a no-op when there is no partial",
                  buffer.committedText == "Already committed. still in flight")
        }
        do {
            let buffer = TextBuffer()
            let before = buffer.revision
            buffer.apply([.insert("speech")])
            check("speech bumps the revision", buffer.revision > before)
            let afterSpeech = buffer.revision
            buffer.userDidEdit("typed by hand")
            check("user edits do not bump the revision", buffer.revision == afterSpeech)
            check("user edits are kept", buffer.committedText == "typed by hand")
        }

        print("Voice Control history")
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-history-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let history = DesktopVoiceHistoryStore(directory: directory)
            let first = UUID()
            history.record(.user, text: "Bring my browser back", detail: "voice", target: "Brave", turnID: first)
            history.record(.plan, text: "Open Brave", turnID: first)
            history.record(.failure, text: "Brave couldn't launch", turnID: first)
            let second = UUID()
            history.record(.user, text: "What happened to it?", detail: "typed", turnID: second)
            let queued = UUID()
            history.record(.user, text: "A later queued instruction", turnID: queued)
            let context = history.contextLines(excluding: second).joined(separator: "\n")
            check("a follow-up receives the earlier request and its actual failure",
                  context.contains("Bring my browser back") && context.contains("Brave couldn't launch"))
            check("context excludes the current request and later queued utterances",
                  !context.contains("What happened to it?") && !context.contains("later queued"))
            let reloaded = DesktopVoiceHistoryStore(directory: directory)
            check("Voice Control transcripts and results survive a restart",
                  reloaded.entries.count == 5 && reloaded.entries.first?.turnID == first)
            check("search returns the whole matching exchange including its failure",
                  reloaded.search("browser").map(\.kind) == [.user, .plan, .failure])
            check("the quick history menu contains only user transcripts, newest first",
                  reloaded.recentTranscripts.map(\.text) == ["A later queued instruction", "What happened to it?", "Bring my browser back"])
            check("the readable export distinguishes proposed plans from actual failures",
                  (try? String(contentsOf: history.recentURL, encoding: .utf8))?.contains("failure: Brave couldn't launch") == true)
            for url in [history.archiveURL, history.recentURL] {
                let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
                check("saved transcripts are readable only by their owner: \(url.lastPathComponent)", mode?.intValue == 0o600)
            }
            history.record(.contextReset, text: "Fresh conversation", turnID: UUID())
            check("clearing active context keeps the saved conversation searchable",
                  history.contextLines().isEmpty && history.search("browser").count == 3)
            let file = try? FileHandle(forWritingTo: history.archiveURL)
            _ = try? file?.seekToEnd()
            try? file?.write(contentsOf: Data("{incomplete".utf8))
            try? file?.close()
            let recovered = DesktopVoiceHistoryStore(directory: directory)
            recovered.record(.user, text: "After recovery", turnID: UUID())
            let final = DesktopVoiceHistoryStore(directory: directory)
            check("a partial trailing log record doesn't lose earlier or subsequent transcripts",
                  final.entries.count == 7 && final.entries.last?.text == "After recovery")
            check("assistant history context stays within its text budget",
                  final.contextLines(maxCharacters: 20).joined(separator: "\n").count <= 20)
            let blocked = DesktopVoiceHistoryStore(directory: history.archiveURL)
            blocked.record(.user, text: "Still visible", turnID: UUID())
            check("a persistence failure remains visible without discarding the current transcript",
                  blocked.saveError != nil && blocked.entries.last?.text == "Still visible")
            let historyCall: [String: Any] = ["output": [["type": "function_call", "name": "search_voice_history",
                "arguments": "{\"query\":\"browser\"}"]]]
            check("the model can retrieve earlier conversation without an exact voice trigger",
                  (try? DesktopVoiceAssistant.interpret(historyCall, resolveApplication: { _ in nil })) == .searchHistory("browser"))
            let historyRequest = DesktopVoiceAssistant.requestBody(utterance: "What did I ask earlier?",
                context: .init(targetName: nil, recentActivity: []), screen: nil, learnedSkills: [], historyMatches: "Previous user: open browser")
            check("retrieved history is available without allowing an unbounded search loop",
                  (historyRequest["input"] as? String)?.contains("Previous user: open browser") == true
                    && !(historyRequest["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "search_voice_history" })
        }

        print("InsertionHistory")
        failures += HistoryInteractionSelfTest.run()
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("btrvoice-history-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }

            let store = InsertionHistoryStore(fileURL: url, maximumEntries: 2)
            store.record(
                text: "first long dictation",
                targetName: "Telegram",
                send: false,
                at: Date(timeIntervalSince1970: 1)
            )
            store.record(
                text: "second long dictation",
                targetName: "Messages",
                send: true,
                at: Date(timeIntervalSince1970: 2)
            )
            store.record(
                text: "newest dictation",
                targetName: nil,
                send: false,
                at: Date(timeIntervalSince1970: 3)
            )

            let reloaded = InsertionHistoryStore(fileURL: url, maximumEntries: 2)
            check("history persists newest first",
                  reloaded.entries.map(\.text) == ["newest dictation", "second long dictation"],
                  "\(reloaded.entries.map(\.text))")
            check("history keeps the original action and target",
                  reloaded.entries.last?.sendsAfterInsertion == true
                  && reloaded.entries.last?.targetName == "Messages")

            do {
                try reloaded.clear()
                let cleared = InsertionHistoryStore(fileURL: url, maximumEntries: 2)
                check("clear history persists", cleared.entries.isEmpty)
            } catch {
                check("clear history persists", false, error.localizedDescription)
            }
        }

        print("TextInjector.chunked")
        do {
            let line = String(repeating: "abcde ", count: 12)
            let chunks = TextInjector.chunked(line)
            check("chunks reassemble losslessly", chunks.joined() == line)
            check("every chunk fits the payload limit",
                  chunks.allSatisfy { $0.utf16.count <= 16 },
                  "\(chunks.map { $0.utf16.count })")
        }
        do {
            // Surrogate pairs and ZWJ sequences must never be cut in half.
            let line = "ok 👍🏽 done 👨‍👩‍👧‍👦 end 🇯🇵"
            let chunks = TextInjector.chunked(line)
            check("emoji survive chunking", chunks.joined() == line, chunks.joined())
            check("no chunk is empty", chunks.allSatisfy { !$0.isEmpty })
        }
        do {
            check("empty line yields no chunks", TextInjector.chunked("").isEmpty)
        }

        DesktopVoiceFlowSelfTest.pure { name, passed in check(name, passed) }
        print(failures == 0 ? "\nAll self-tests passed." : "\n\(failures) self-test(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
