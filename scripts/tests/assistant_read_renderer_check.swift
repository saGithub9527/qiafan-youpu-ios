import Foundation

// Only the existing localization facade is substituted; no business success is mocked in production.
@MainActor final class QFAppSession {
  func text(_ chinese: String, _ english: String) -> String { english }
  func format(_ chinese: String, _ english: String, _ arguments: CVarArg...) -> String { String(format: english, arguments: arguments) }
}

@main enum ReadRendererCheck {
  @MainActor static func main() throws {
    let result = QFAgentToolResult(name: "inventory.read", status: "SUCCEEDED",
      evidence: #"{"items":[{"ingredientName":"豆腐","quantity":"2.50","unitCode":"kg","excludedFromPlanningReasons":["EXPIRED"],"expiresOn":"2026-10-10"}],"truncated":true}"#,
      sources: [], action: nil)
    let text = try QFAssistantReadRenderer.render([result], app: QFAppSession())
    precondition(text.contains("2.50 kg"), "Actual decimal quantity must be retained")
    precondition(text.contains("Needs review") && text.contains("2026-10-10"))
    precondition(text.contains("Only part"), "Partial stock must be explicit")
    let failure = QFAgentToolResult(name: "inventory.read", status: "FAILED", evidence: "{}", sources: [], action: nil)
    do { _ = try QFAssistantReadRenderer.render([failure], app: QFAppSession()); fatalError("Failure shown as success") }
    catch { }
    print("PASS actual stock quantity, expiry, partial-data and failure rendering checks")
  }
}
