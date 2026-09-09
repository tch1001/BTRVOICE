/// A successful HTTP request is not necessarily a complete model response. Never
/// execute a cut-off tool call; retry the same request once with a bounded budget.
import Foundation

enum DesktopModelResponse {
    static func retryBudget(_ body: [String: Any], budget: Int, attempt: Int) -> Int? {
        guard attempt == 0, body["status"] as? String == "incomplete",
              (body["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens" else { return nil }
        return min(8_000, max(2_400, budget * 2))
    }

    static func requireComplete(_ body: [String: Any]) throws {
        if let status = body["status"] as? String, status != "completed" {
            let reason = (body["incomplete_details"] as? [String: Any])?["reason"] as? String ?? status
            throw DesktopVoiceAssistant.AssistantError.invalidPlan("The model response was unfinished (\(reason)); no tool was executed.")
        }
        for item in body["output"] as? [[String: Any]] ?? [] {
            if let status = item["status"] as? String, status != "completed" {
                throw DesktopVoiceAssistant.AssistantError.invalidPlan("An output item is unfinished; no tool was executed.")
            }
        }
    }
}
