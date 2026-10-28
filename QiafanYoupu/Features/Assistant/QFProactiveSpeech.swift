@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Uptime-based policy, independent of wall-clock changes and UI refreshes.
struct QFProactiveSpeechSchedule {
  static let interval: TimeInterval = 300
  private(set) var binding: String?
  private var deadline: TimeInterval?
  private var foreground = false

  var nextDeadline: TimeInterval? { foreground ? deadline : nil }

  mutating func bind(_ value: String?, at now: TimeInterval) {
    guard value != binding else { return }
    binding = value
    deadline = value == nil ? nil : now + Self.interval
  }

  mutating func setForeground(_ active: Bool, at now: TimeInterval) {
    if active && !foreground { discardMissed(at: now) }
    foreground = active
  }

  mutating func discardMissed(at now: TimeInterval) {
    if let deadline, deadline <= now { self.deadline = now + Self.interval }
  }

  mutating func claim(at now: TimeInterval, permitted: Bool) -> Bool {
    guard foreground, binding != nil, let deadline, now >= deadline else { return false }
    self.deadline = now + Self.interval
    return permitted
  }
}

enum QFProactiveSpeechPreferences {
  private static let prefix = "qf.assistant.proactive-speech.enabled."
  static func isEnabled(scope: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: prefix + scope) as? Bool ?? true
  }
  static func setEnabled(_ value: Bool, scope: String, defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: prefix + scope)
    NotificationCenter.default.post(name: .qfLocalSettingsDidChange, object: nil,
      userInfo: ["scope": scope, "proactiveSpeech": value])
  }
  static func forget(scope: String, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: prefix + scope)
  }
}

struct QFProactiveSpeechContext: Equatable {
  let binding: String
  let language: QFInterfaceLanguage
  let text: String

  static func greeting(for language: QFInterfaceLanguage, bundle: Bundle = .main) -> String? {
    let key = "今天想吃什么？打开助手一起安排。"
    if language == .simplifiedChinese { return key }
    if language == .english { return "What would you like to eat today? Open the assistant to plan it together." }
    guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
      let localized = Bundle(path: path) else { return nil }
    let missing = "__QF_MISSING_PROACTIVE_GREETING__"
    let value = localized.localizedString(forKey: key, value: missing, table: nil)
    return value == missing || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
  }
}

/// Owns one cancellable foreground timer and an actual system synthesizer.
/// No microphone permission, network request, model call or missed-speech queue.
@MainActor
final class QFProactiveSpeechController: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private let contextProvider: () -> QFProactiveSpeechContext?
  private let canSpeak: () -> Bool
  private let onStart: (String) -> Void
  private let onEnd: () -> Void
  private weak var scene: UIWindowScene?
  private var sceneActive = false
  private var appActive = UIApplication.shared.applicationState == .active
  private var interrupted = false
  private var secondaryAudio = false
  private var context: QFProactiveSpeechContext?
  private var schedule = QFProactiveSpeechSchedule()
  private var timer: Task<Void, Never>?
  private var generation = UUID()
  private var utterance: AVSpeechUtterance?
  private var observers: [NSObjectProtocol] = []
  private var audioBeforeSpeech: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

  init(context: @escaping () -> QFProactiveSpeechContext?, canSpeak: @escaping () -> Bool,
       onStart: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
    contextProvider = context; self.canSpeak = canSpeak; self.onStart = onStart; self.onEnd = onEnd
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
    observeLifecycle()
  }

  deinit {
    timer?.cancel()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    let speech = synthesizer
    let previous = audioBeforeSpeech
    Task { @MainActor in
      speech.stopSpeaking(at: .immediate)
      let audio = AVAudioSession.sharedInstance()
      if let previous, audio.category == .ambient, audio.mode == .default {
        try? audio.setActive(false, options: [.notifyOthersOnDeactivation])
        try? audio.setCategory(previous.0, mode: previous.1, options: previous.2)
      }
    }
  }

  func refresh(in scene: UIWindowScene?) {
    if self.scene !== scene {
      cancelTimer(); stopUtterance()
      self.scene = scene
      sceneActive = scene?.activationState == .foregroundActive
    }
    synchronize(armTimer: true)
  }

  func stop() {
    cancelTimer(); stopUtterance()
    context = nil; schedule.bind(nil, at: ProcessInfo.processInfo.systemUptime)
  }

  private func synchronize(armTimer: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    let latest = contextProvider()
    if latest != context {
      cancelTimer(); stopUtterance(); context = latest
      schedule.bind(latest?.binding, at: now)
    }
    let active = scene != nil && sceneActive && appActive
    schedule.setForeground(active, at: now)
    guard active, latest != nil, !interrupted, !secondaryAudio else {
      cancelTimer(); stopUtterance(); return
    }
    if armTimer { arm() }
  }

  private func arm() {
    guard timer == nil, let deadline = schedule.nextDeadline else { return }
    let delay = max(0.05, min(3_600, deadline - ProcessInfo.processInfo.systemUptime))
    let run = generation
    timer = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
      guard let self, self.generation == run else { return }
      self.timer = nil
      self.attempt()
    }
  }

  private func attempt() {
    synchronize(armTimer: false)
    let audio = AVAudioSession.sharedInstance()
    let allowed = !interrupted && !secondaryAudio && canSpeak()
      && !UIAccessibility.isVoiceOverRunning && !synthesizer.isSpeaking
      && !audio.isOtherAudioPlaying && !audio.secondaryAudioShouldBeSilencedHint
    guard schedule.claim(at: ProcessInfo.processInfo.systemUptime, permitted: allowed),
      let context, let voice = Self.voice(for: context.language) else { arm(); return }
    let previous = (audio.category, audio.mode, audio.categoryOptions)
    do {
      // Ambient respects the hardware silent switch and does not seize another
      // app's audio. The app's recording/chat/form gate is checked above.
      try audio.setCategory(.ambient, mode: .default, options: [])
      try audio.setActive(true)
      audioBeforeSpeech = previous
    } catch {
      try? audio.setCategory(previous.0, mode: previous.1, options: previous.2)
      arm(); return
    }
    let value = AVSpeechUtterance(string: context.text)
    value.voice = voice
    utterance = value
    synthesizer.speak(value)
    arm()
  }

  private static func voice(for language: QFInterfaceLanguage) -> AVSpeechSynthesisVoice? {
    let preferred: String
    switch language {
    case .simplifiedChinese: preferred = "zh-CN"
    case .traditionalChinese: preferred = "zh-TW"
    case .english: preferred = "en-US"
    case .japanese: preferred = "ja-JP"
    case .korean: preferred = "ko-KR"
    case .russian: preferred = "ru-RU"
    case .spanish: preferred = "es-ES"
    case .french: preferred = "fr-FR"
    case .german: preferred = "de-DE"
    case .portugueseBrazil: preferred = "pt-BR"
    }
    // A missing current-language voice means no utterance; never use the
    // synthesizer's default voice or an old-language voice as a substitute.
    return AVSpeechSynthesisVoice.speechVoices().first { $0.language == preferred }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart value: AVSpeechUtterance) {
    guard utterance === value, context == contextProvider(), sceneActive, appActive else {
      stopUtterance(); return
    }
    onStart(value.speechString)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish value: AVSpeechUtterance) {
    finish(value)
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel value: AVSpeechUtterance) {
    finish(value)
  }
  private func finish(_ value: AVSpeechUtterance) {
    guard utterance === value else { return }
    utterance = nil; releaseAudio(); onEnd()
  }
  private func stopUtterance() {
    guard utterance != nil else { return }
    utterance = nil; synthesizer.stopSpeaking(at: .immediate); releaseAudio(); onEnd()
  }
  private func cancelTimer() { generation = UUID(); timer?.cancel(); timer = nil }
  private func releaseAudio() {
    guard let previous = audioBeforeSpeech else { return }
    audioBeforeSpeech = nil
    let audio = AVAudioSession.sharedInstance()
    // A different audio owner may have changed the session meanwhile.
    guard audio.category == .ambient, audio.mode == .default else { return }
    try? audio.setActive(false, options: [.notifyOthersOnDeactivation])
    try? audio.setCategory(previous.0, mode: previous.1, options: previous.2)
  }

  private func observe(_ name: Notification.Name, action: @escaping (QFProactiveSpeechController, Notification) -> Void) {
    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
      Task { @MainActor [weak self] in guard let self else { return }; action(self, note) }
    })
  }
  private func observeLifecycle() {
    observe(UIApplication.willResignActiveNotification) { owner, _ in
      owner.appActive = false; owner.synchronize(armTimer: true)
    }
    observe(UIApplication.didBecomeActiveNotification) { owner, _ in
      owner.appActive = true; owner.synchronize(armTimer: true)
    }
    for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification] {
      observe(name) { owner, note in
        guard (note.object as? UIScene) === owner.scene else { return }
        owner.sceneActive = false; owner.synchronize(armTimer: true)
      }
    }
    observe(UIScene.didActivateNotification) { owner, note in
      guard (note.object as? UIScene) === owner.scene else { return }
      owner.sceneActive = true; owner.synchronize(armTimer: true)
    }
    observe(AVAudioSession.interruptionNotification) { owner, note in
      guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      owner.interrupted = type == .began
      if type == .ended { owner.schedule.discardMissed(at: ProcessInfo.processInfo.systemUptime) }
      owner.synchronize(armTimer: true)
    }
    observe(AVAudioSession.silenceSecondaryAudioHintNotification) { owner, note in
      guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt else { return }
      owner.secondaryAudio = raw == AVAudioSession.SilenceSecondaryAudioHintType.begin.rawValue
      if !owner.secondaryAudio { owner.schedule.discardMissed(at: ProcessInfo.processInfo.systemUptime) }
      owner.synchronize(armTimer: true)
    }
    observe(AVAudioSession.routeChangeNotification) { owner, note in
      guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      owner.stopUtterance()
    }
    observe(UIAccessibility.voiceOverStatusDidChangeNotification) { owner, _ in
      if UIAccessibility.isVoiceOverRunning { owner.stopUtterance() }
    }
  }
}
