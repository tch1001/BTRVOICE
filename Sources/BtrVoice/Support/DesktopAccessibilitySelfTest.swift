/// Protects the boundary between model-selected UI operations and native effects.
/// These checks deliberately require neither Accessibility permission nor a real app.
import ApplicationServices
import Foundation

enum DesktopAccessibilitySelfTest {
    static func run(check: (String, Bool) -> Void) {
        print("Accessibility control")
        let ref = AXUIElementCreateApplication(42)
        let button = DesktopAccessibilityElement(id: "e1", reference: ref, parentID: nil, role: "AXButton",
            label: "Unread", actions: ["AXPress", "AXShowMenu"], writable: ["AXFocused": .boolean], enabled: true)
        var context = DesktopAccessibilityContext(text: "Unread", elementCount: 1, truncated: false)
        context.processIdentifier = 42
        context.elements = [button.id: button]
        func command(_ action: String = "AXPress", snapshot: String? = nil, id: String = "e1") -> DesktopUICommand {
            DesktopUICommand(snapshotID: snapshot ?? context.snapshotID, elementID: id, action: action)
        }
        func accepts(_ cmd: DesktopUICommand, _ ctx: DesktopAccessibilityContext? = nil, pid: pid_t? = 42) -> Bool {
            (try? DesktopAccessibilityControl.validate(cmd, in: ctx ?? context, activePID: pid)) != nil
        }
        check("a current enabled button can perform its advertised press", accepts(command()))
        check("app-specific advertised actions are not restricted to a hard-coded action list", accepts(command("AXShowMenu")))
        check("unadvertised actions are refused", !accepts(command("AXInvented")))
        check("controls from a previous snapshot cannot be replayed", !accepts(command(snapshot: "old")))
        check("invented element identifiers cannot target a native element", !accepts(command(id: "e999")))
        check("switching apps prevents a pending control action", !accepts(command(), pid: 43))
        check("missing foreground identity prevents an action", !accepts(command(), pid: nil))
        var old = context; old.capturedAt = Date().addingTimeInterval(-61)
        check("a snapshot expires while the model is thinking", !accepts(command(), old))
        var disabled = context
        disabled.elements["e1"] = DesktopAccessibilityElement(id: "e1", reference: ref, parentID: nil,
            role: "AXButton", label: "Unread", actions: ["AXPress"], writable: [:], enabled: false)
        check("disabled controls cannot be pressed", !accepts(command(), disabled))
        let focus = DesktopUICommand(snapshotID: context.snapshotID, elementID: "e1", attribute: "AXFocused", valueJSON: "true")
        check("focus uses a typed boolean attribute", accepts(focus))
        check("a control cannot receive a text write through a generic attribute",
            !accepts(DesktopUICommand(snapshotID: context.snapshotID, elementID: "e1", attribute: "AXValue", valueJSON: "\"injected\"")))
        check("a boolean cannot be smuggled in as a number", (try? DesktopAXValue.decode("true", as: .number)) == nil)
        check("a number cannot be smuggled in as a boolean", (try? DesktopAXValue.decode("1", as: .boolean)) == nil)
        check("negative desktop coordinates work on multiple displays",
            (try? DesktopAXValue.decode("{\"x\":-100,\"y\":-200}", as: .point)) == .point(-100, -200))
        check("window size must remain positive", (try? DesktopAXValue.decode("{\"width\":0,\"height\":600}", as: .size)) == nil)
        check("text selection cannot have fractional offsets", (try? DesktopAXValue.decode("{\"location\":0.5,\"length\":1}", as: .range)) == nil)
        check("text selection cannot overflow native range arithmetic", (try? DesktopAXValue.decode("{\"location\":1e30,\"length\":1}", as: .range)) == nil)
        check("extra value fields are refused", (try? DesktopAXValue.decode("{\"x\":0,\"y\":0,\"shell\":\"hi\"}", as: .point)) == nil)
        context.elements["e2"] = DesktopAccessibilityElement(id: "e2", reference: ref, parentID: nil,
            role: "AXSlider", label: "Volume", actions: [], writable: ["AXValue": .number], enabled: true,
            minimum: 0, maximum: 100)
        check("sliders accept in-range numeric settings", accepts(DesktopUICommand(snapshotID: context.snapshotID,
            elementID: "e2", attribute: "AXValue", valueJSON: "75")))
        check("slider bounds are enforced before any native write", !accepts(DesktopUICommand(snapshotID: context.snapshotID,
            elementID: "e2", attribute: "AXValue", valueJSON: "101")))
        context.elements["e3"] = DesktopAccessibilityElement(id: "e3", reference: ref, parentID: nil,
            role: "AXTable", label: "Chats", actions: [], writable: ["AXSelectedRows": .elements], enabled: true)
        context.elements["e4"] = DesktopAccessibilityElement(id: "e4", reference: ref, parentID: "e3",
            role: "AXRow", label: "Unread", actions: [], writable: [:], enabled: true)
        check("table selections can reference their own rows", accepts(DesktopUICommand(snapshotID: context.snapshotID,
            elementID: "e3", attribute: "AXSelectedRows", valueJSON: "[\"e4\"]")))
        check("table selections cannot reference a different container's control", !accepts(DesktopUICommand(snapshotID: context.snapshotID,
            elementID: "e3", attribute: "AXSelectedRows", valueJSON: "[\"e2\"]")))
        check("unknown row references are refused", !accepts(DesktopUICommand(snapshotID: context.snapshotID,
            elementID: "e3", attribute: "AXSelectedRows", valueJSON: "[\"e999\"]")))
        check("text fields never advertise AX text insertion", DesktopAccessibilityControl.writableKinds(role: "AXTextField")["AXValue"] == nil)
        check("scroll bars advertise numeric adjustment", DesktopAccessibilityControl.writableKinds(role: "AXScrollBar")["AXValue"] == .number)

        let call: [String: Any] = ["snapshot_id": context.snapshotID, "element_id": "e1", "action": "AXPress"]
        var mixed = call; mixed["attribute"] = "AXFocused"; mixed["value_json"] = "true"
        check("one tool call cannot hide multiple mutations", (try? DesktopUICommand(arguments: mixed)) == nil)
        var extra = call; extra["pid"] = 99
        check("the model cannot supply a process identifier", (try? DesktopUICommand(arguments: extra)) == nil)
        let resolve: DesktopVoiceAssistant.ApplicationResolver = { _ in nil }
        let output: [String: Any] = ["type": "function_call", "name": "control_ui", "arguments": call]
        check("control tools compile to typed decisions",
            (try? DesktopVoiceAssistant.interpret(["output": [output]], resolveApplication: resolve)) == .controlUI(command()))
        check("multiple returned tool calls cannot partially execute",
            (try? DesktopVoiceAssistant.interpret(["output": [output, output]], resolveApplication: resolve)) == nil)
        let snapshot = DesktopScreenSnapshot(jpeg: nil, width: 0, height: 0, displayID: 0, application: "Fixture", capturedAt: Date(), accessibility: context)
        func allows(_ decision: DesktopVoiceAssistantDecision, armed: Bool) -> Bool {
            do { try DesktopVoiceAssistant.validate(decision, screen: snapshot, allowsUIActions: armed); return true }
            catch { return false }
        }
        check("a read-only screen question cannot acquire action authority", !allows(.beginUIControl, armed: false))
        check("a read-only screen response cannot press a button", !allows(.controlUI(command()), armed: false))
        check("an authorized UI task can request a button press", allows(.controlUI(command()), armed: true))
        let readOnly = DesktopVoiceAssistant.requestBody(utterance: "Describe the screen", context: .init(targetName: "Fixture", recentActivity: []), screen: snapshot, learnedSkills: [])
        let active = DesktopVoiceAssistant.requestBody(utterance: "Click Unread", context: .init(targetName: "Fixture", recentActivity: [], allowsUIActions: true), screen: snapshot, learnedSkills: [])
        func toolNames(_ request: [String: Any]) -> [String] { (request["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
        check("read-only snapshots expose no action or teaching tools", !toolNames(readOnly).contains("control_ui") && !toolNames(readOnly).contains("run_desktop_plan") && !toolNames(readOnly).contains("teach_fast_path"))
        check("UI interaction snapshots expose native controls and desktop plans", toolNames(active).contains("control_ui") && toolNames(active).contains("run_desktop_plan"))
        check("screens cannot turn a one-off interaction into a learned skill", !toolNames(active).contains("teach_fast_path"))
        check("all new tool schemas remain JSON encodable", JSONSerialization.isValidJSONObject(active))
        let continuation = DesktopVoiceAssistant.continuing(active, output: [["type": "function_call",
            "name": "control_ui", "arguments": "{}", "call_id": "call-fixture"]], result: "The slider is now 75.")
        let continuedInput = continuation["input"] as? [[String: Any]] ?? []
        check("an executed tool gets its matching function result before the fresh screen",
            continuedInput.count == 4 && continuedInput[1]["type"] as? String == "function_call"
                && continuedInput[2]["type"] as? String == "function_call_output"
                && continuedInput[2]["call_id"] as? String == "call-fixture"
                && continuedInput[3]["content"] is [[String: Any]])
        check("the original user request is not repeated after a completed tool",
            continuedInput.last?["content"] is [[String: Any]]
                && !(String(describing: continuedInput.last?["content"]).contains("Latest user request")))
        check("tool continuations remain JSON encodable", JSONSerialization.isValidJSONObject(continuation))
    }
}
