import Foundation

/// Small, device-local conversation cache. It is deliberately capped and keyed by account;
/// server memory is opt-in and is never inferred from this cache.
final class QFAssistantConversationStore {
  private let key: String
  private let persistent: Bool
  private let defaults: UserDefaults
  let mediaScope: String
  private var ownedImages = Set<String>()
  private struct ContextRecord: Codable {
    let id: UUID
    let role: String
    let text: String
    let hasImage: Bool
  }
  private struct ContextSnapshot: Codable {
    let records: [ContextRecord]
    let boundary: UUID?
    let nativeCapacity: Bool
  }
  private var contextRecords: [ContextRecord] = []
  private var contextBoundary: UUID?
  private var contextUnavailable = false
  private(set) var nativeCapacityReached = false
  init(scope: QFAgentScope, persistent: Bool = true, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.persistent = persistent
    mediaScope = "assistant-chat|" + scope.cacheKey
    key = "qf.assistant.conversation.v2.\(scope.cacheKey)"
    if persistent {
      // No context key is the first-upgrade case: retain the established visible-chat import.
      guard let stored = defaults.object(forKey: key + ".context") else { return }
      guard let saved = stored as? Data, saved.count <= 1_048_576 else { contextUnavailable = true; return }
      if let snapshot = try? JSONDecoder().decode(ContextSnapshot.self, from: saved), Self.valid(snapshot.records) {
        contextRecords = snapshot.records; contextBoundary = snapshot.boundary
        nativeCapacityReached = snapshot.nativeCapacity
      } else if let records = try? JSONDecoder().decode([ContextRecord].self, from: saved), Self.valid(records) {
        // [] plus retained chat may be only the first half of the old split reset.
        // Do not guess a boundary or overwrite those bytes during recovery.
        guard !records.isEmpty || !hasVisibleOrUnreadableChat() else { contextUnavailable = true; return }
        let oldBoundary = defaults.string(forKey: key + ".contextBoundary")
        if let oldBoundary, UUID(uuidString: oldBoundary) == nil { contextUnavailable = true; return }
        contextRecords = records; contextBoundary = oldBoundary.flatMap(UUID.init(uuidString:))
        nativeCapacityReached = defaults.bool(forKey: key + ".nativeCapacity")
        // The next save/capacity/reset write migrates this valid legacy value as one snapshot.
      } else { contextUnavailable = true }
    }
  }
  private static func valid(_ records: [ContextRecord]) -> Bool {
    Set(records.map(\.id)).count == records.count && records.allSatisfy { ["user", "assistant"].contains($0.role) }
  }
  private func hasVisibleOrUnreadableChat() -> Bool {
    guard let stored = defaults.object(forKey: key) else { return false }
    guard let data = stored as? Data,
      let messages = try? JSONDecoder().decode([QFAssistantLocalMessage].self, from: data) else { return true }
    return messages.suffix(40).contains { $0.role != "thinking" }
  }
  private func persistContext() {
    guard persistent, !contextUnavailable else { return }
    let snapshot = ContextSnapshot(records: contextRecords, boundary: contextBoundary, nativeCapacity: nativeCapacityReached)
    guard let data = try? JSONEncoder().encode(snapshot), data.count <= 1_048_576 else { contextUnavailable = true; return }
    // Reset boundary, records and the overflow guard cannot survive as separate partial writes.
    defaults.set(data, forKey: key + ".context")
  }
  func load() -> [QFAssistantLocalMessage] {
    guard persistent else { return [] }
    guard let data = defaults.data(forKey: key),
      let value = try? JSONDecoder().decode([QFAssistantLocalMessage].self, from: data)
    else { return [] }
    let registered = Set(defaults.stringArray(forKey: key + ".images") ?? value.compactMap(\.imageID))
    let visible = Set(value.suffix(40).compactMap(\.imageID))
    for id in registered.subtracting(visible) { QFLocalMediaStore.remove(id, scope: mediaScope) }
    ownedImages = visible
    defaults.set(Array(visible), forKey: key + ".images")
    return Array(value.filter { $0.role != "thinking" }.suffix(40)).map { original in
      var item = original
      if item.state == "streaming" { item.state = "stopped"; item.process = item.process?.map { step in
        var step = step; if step.state == "running" { step.state = "stopped" }; return step
      } }
      return item
    }
  }
  func save(_ messages: [QFAssistantLocalMessage]) {
    if !contextUnavailable {
      contextRecords = mergedContext(messages)
      persistContext()
    }
    guard persistent else { return }
    let value = Array(messages.suffix(40))
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
    let retained = Set(messages.compactMap(\.imageID))
    // Only files created for this conversation and aged out of its existing
    // 40-message retention. Never clear another draft/account media directory.
    for id in ownedImages.subtracting(retained) { QFLocalMediaStore.remove(id, scope: mediaScope) }
    ownedImages = retained
    defaults.set(Array(retained), forKey: key + ".images")
  }
  private func activeMessages(_ messages: [QFAssistantLocalMessage]) -> [QFAssistantLocalMessage] {
    let boundary = contextBoundary.flatMap { id in messages.firstIndex { $0.id == id } }
    return boundary.map { Array(messages.dropFirst($0 + 1)) } ?? messages
  }
  func knownSources(_ messages: [QFAssistantLocalMessage]) -> [QFAgentSource] {
    guard !contextUnavailable else { return [] }
    return activeMessages(messages).last { $0.role == "assistant"
      && !["streaming", "stopped", "failed"].contains($0.state ?? "") }?.sources ?? []
  }
  /// Visible chat retention and the active task context are separate. No prose
  /// summary, private-profile write, or cross-account cache is involved.
  private func mergedContext(_ messages: [QFAssistantLocalMessage]) -> [ContextRecord] {
    var records = contextRecords
    var positions = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
    for message in activeMessages(messages) where ["user", "assistant"].contains(message.role)
      && !["streaming", "stopped", "failed"].contains(message.state ?? "")
      && (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.imageID != nil) {
      let record = ContextRecord(id: message.id, role: message.role, text: message.text, hasImage: message.imageID != nil)
      if let index = positions[message.id] { records[index] = record }
      else { positions[message.id] = records.count; records.append(record) }
    }
    return records
  }
  func history(_ messages: [QFAssistantLocalMessage], imageQuestion: String) throws -> [QFAgentConversationContext.Turn] {
    guard !contextUnavailable else { throw QFAgentConversationContext.Invalid.schema }
    return mergedContext(messages).map {
      .init(role: $0.role, content: $0.text.isEmpty && $0.hasImage ? imageQuestion : $0.text)
    }
  }
  /// Remember a native overflow without changing visible chat or user preferences.
  func markNativeCapacityReached() {
    nativeCapacityReached = true
    persistContext()
  }
  /// Invoked only after the user explicitly chooses a new context. Existing
  /// visible messages, media, model and other preferences are preserved.
  func beginNewContext(after messageID: UUID?) {
    contextRecords = []; contextUnavailable = false; contextBoundary = messageID; nativeCapacityReached = false
    persistContext()
  }
  func saveImage(_ data: Data) throws -> String {
    let id = try QFLocalMediaStore.save(data, video: false, scope: mediaScope).id
    ownedImages.insert(id)
    if persistent { defaults.set(Array(ownedImages), forKey: key + ".images") }
    return id
  }
  func imageURL(_ id: String?) -> URL? {
    guard let id else { return nil }; return try? QFLocalMediaStore.url(id, scope: mediaScope)
  }
}
