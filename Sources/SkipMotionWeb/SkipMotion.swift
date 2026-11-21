// Copyright 2023–2026 Skip
import SwiftUIWeb
import SwiftUIWebWeb

// SkipMotion for the web, built when SwiftUIWeb's browser build evaluates Package.swift (SWIFTUIWEB_EMBEDDED). The API is
// the one Sources/SkipMotion has on iOS and Android; lottie-web draws the animation, in a JavaScript component the page
// registers as "skip-motion" (Web/Resources/skip-motion.js), mounted through SwiftUIWeb's DOMViewRepresentable.
//
// The component's state is one line of JSON with what to play, a line break, and the Lottie JSON text:
//   {"mode":"play"|"pause","loop":"once"|"loop"|"autoreverse"|"repeat:<n>"|"repeat-backwards:<n>","speed":<n>,
//    "from":<n>|null,"to":<n>|null,"progress":<n>|null,"frame":<n>|null,"fill":<bool>}
// It posts "1" when a playback ends and "0" when a pause or a new playback cuts it short (`onComplete`).

/// Defines animation loop behavior.
public enum MotionLoopMode: Hashable, Sendable {
    /// Animation is played once then stops.
    case playOnce
    /// Animation will loop from beginning to end until stopped.
    case loop
    /// Animation will play forward, then backwards and loop until stopped.
    case autoReverse
    /// Animation will loop from beginning to end up to defined amount of times.
    case `repeat`(Int)
    /// Animation will play forward, then backwards a defined amount of times.
    case repeatBackwards(Int)

    var componentValue: String {
        switch self {
        case .playOnce: return "once"
        case .loop: return "loop"
        case .autoReverse: return "autoreverse"
        case .repeat(let count): return "repeat:\(max(0, count))"
        case .repeatBackwards(let count): return "repeat-backwards:\(max(0, count))"
        }
    }
}

/// Defines how the animation content is scaled within its bounds.
public enum MotionContentMode: Hashable, Sendable {
    /// Scale the animation to fit within the bounds while preserving aspect ratio.
    case fit
    /// Scale the animation to fill the bounds while preserving aspect ratio, cropping if needed.
    case fill
}

/// A MotionView embeds an animation in the Lottie JSON format.
public struct MotionView: View {
    let lottieContainer: LottieContainer?
    let animationSpeed: Double
    let loopMode: MotionLoopMode
    let isPlaying: Bool
    let contentMode: MotionContentMode
    let currentProgress: Double?
    let fromProgress: Double?
    let toProgress: Double?
    let enableMergePaths: Bool
    let currentFrame: CGFloat?
    let onComplete: ((Bool) -> Void)?

    public init(lottie lottieData: Data, animationSpeed: Double = 1.0, loopMode: MotionLoopMode = .loop, isPlaying: Bool = true, contentMode: MotionContentMode = .fit, currentProgress: Double? = nil, fromProgress: Double? = nil, toProgress: Double? = nil, enableMergePaths: Bool = false, currentFrame: CGFloat? = nil, onComplete: ((Bool) -> Void)? = nil) {
        // As on iOS and Android, data that is not a Lottie animation draws nothing.
        self.lottieContainer = try? LottieContainer(data: lottieData)
        self.animationSpeed = animationSpeed
        self.loopMode = loopMode
        self.isPlaying = isPlaying
        self.contentMode = contentMode
        self.currentProgress = currentProgress
        self.fromProgress = fromProgress
        self.toProgress = toProgress
        self.enableMergePaths = enableMergePaths
        self.currentFrame = currentFrame
        self.onComplete = onComplete
    }

    public init(lottie lottieContainer: LottieContainer, animationSpeed: Double = 1.0, loopMode: MotionLoopMode = .loop, isPlaying: Bool = true, contentMode: MotionContentMode = .fit, currentProgress: Double? = nil, fromProgress: Double? = nil, toProgress: Double? = nil, enableMergePaths: Bool = false, currentFrame: CGFloat? = nil, onComplete: ((Bool) -> Void)? = nil) {
        self.lottieContainer = lottieContainer
        self.animationSpeed = animationSpeed
        self.loopMode = loopMode
        self.isPlaying = isPlaying
        self.contentMode = contentMode
        self.currentProgress = currentProgress
        self.fromProgress = fromProgress
        self.toProgress = toProgress
        self.enableMergePaths = enableMergePaths
        self.currentFrame = currentFrame
        self.onComplete = onComplete
    }

    /// The playback SkipMotion asks lottie-ios for: a range only when it runs forward, a paused position from the
    /// progress first and the frame second. lottie-web always draws merge paths, so `enableMergePaths` changes nothing.
    var playback: String {
        func number(_ value: Double?) -> String { value.map { String($0) } ?? "null" }
        var from: Double? = nil
        var to: Double? = nil
        var progress: Double? = nil
        var frame: Double? = nil
        if isPlaying {
            if let start = fromProgress, let end = toProgress, start < end { from = start; to = end }
        } else if let currentProgress {
            progress = currentProgress
        } else if let currentFrame {
            frame = Double(currentFrame)
        }
        return "{\"mode\":\"\(isPlaying ? "play" : "pause")\",\"loop\":\"\(loopMode.componentValue)\",\"speed\":\(number(animationSpeed)),"
            + "\"from\":\(number(from)),\"to\":\(number(to)),\"progress\":\(number(progress)),\"frame\":\(number(frame)),"
            + "\"fill\":\(contentMode == .fill ? "true" : "false")}"
    }

    public var body: some View {
        if let lottieContainer {
            // A resizable LottieView takes the space it is offered.
            LottieDOMView(state: playback + "\n" + lottieContainer.json, onComplete: onComplete)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The page's "skip-motion" component in a host of its own.
private struct LottieDOMView: DOMViewRepresentable {
    let state: String
    let onComplete: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeDOMView(context: Context) -> DOMView {
        let domView = DOMView(component: "skip-motion", state: state)
        let coordinator = context.coordinator
        domView.onMessage = { message in
            coordinator.onComplete?(message == "1")
        }
        return domView
    }

    func updateDOMView(_ domView: DOMView, context: Context) {
        context.coordinator.onComplete = onComplete
        domView.state = state
    }

    final class Coordinator {
        var onComplete: ((Bool) -> Void)?
        init(onComplete: ((Bool) -> Void)?) {
            self.onComplete = onComplete
        }
    }
}

/// A container for Lottie data, which is an After Effects/Bodymovin JSON composition model.
///
/// This is the serialized model from which the animation will be created. It is designed to be stateless, cacheable, and shareable.
/// The format is described at [https://lottie.github.io/lottie-spec/](https://lottie.github.io/lottie-spec/).
///
/// On the web this holds the JSON text, which lottie-web draws, and the composition's header (its frames and size).
public struct LottieContainer: Sendable {
    let json: String
    let header: LottieHeader

    /// Creates a Lottie container with the data represented by the given Lottie JSON, or by a dotLottie (`.lottie`)
    /// archive, whose first animation it reads.
    public init(data lottieData: Data) throws {
        var bytes = Array(lottieData)
        if DotLottieArchive.isArchive(bytes) {
            bytes = try DotLottieArchive.animationJSON(bytes)
        }
        guard let header = LottieHeader(scanning: bytes) else { throw LottieContainerError.notAnAnimation }
        self.header = header
        self.json = String(decoding: bytes, as: UTF8.self)
    }

    public var duration: TimeInterval {
        header.framerate > 0 ? (header.endFrame - header.startFrame) / header.framerate : 0
    }

    public var startFrame: CGFloat { header.startFrame }

    public var endFrame: CGFloat { header.endFrame }

    public var framerate: Double { header.framerate }

    public var width: Double { bounds.width }

    public var height: Double { bounds.height }

    public var bounds: CGRect { CGRect(x: 0, y: 0, width: header.width, height: header.height) }
}

enum LottieContainerError: Error {
    case notAnAnimation
}

/// The top-level numbers of a Lottie composition: `ip` and `op` (its first and last frame), `fr` (frames per second),
/// `w` and `h` (its size). They are read by one pass over the object's top level, which skips every nested value without
/// building it: a composition is mostly layers, which lottie-web parses itself.
struct LottieHeader: Hashable, Sendable {
  var startFrame: Double = 0
  var endFrame: Double = 0
  var framerate: Double = 0
  var width: Double = 0
  var height: Double = 0

  /// Nil when the bytes are not a JSON object with a positive frame rate, a last frame after the first, and layers.
  init?(scanning bytes: [UInt8]) {
    var scanner = JSONTopLevelScanner(bytes: bytes)
    var found: Set<String> = []
    let complete = scanner.scanObject { key, scanner in
      switch key {
      case "ip", "op", "fr", "w", "h":
        guard let number = scanner.number() else { return false }
        found.insert(key)
        switch key {
        case "ip": startFrame = number
        case "op": endFrame = number
        case "fr": framerate = number
        case "w": width = number
        default: height = number
        }
        return true
      case "layers":
        found.insert(key)
        return scanner.skipValue()
      default:
        return scanner.skipValue()
      }
    }
    guard complete, found.isSuperset(of: ["ip", "op", "fr", "layers"]), framerate > 0, endFrame > startFrame else { return nil }
  }
}

/// A forward reader of JSON text that visits the keys of the top-level object and skips the values it is not asked for.
struct JSONTopLevelScanner {
  private let bytes: [UInt8]
  private var index = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  /// Calls `visit` with each key of the top-level object, positioned at its value, which `visit` must consume (a number
  /// or a skip). False when the text is not a well-formed object or `visit` returns false.
  mutating func scanObject(_ visit: (String, inout JSONTopLevelScanner) -> Bool) -> Bool {
    skipWhitespace()
    // A UTF-8 byte order mark before the object.
    if index + 2 < bytes.count, bytes[index] == 0xEF, bytes[index + 1] == 0xBB, bytes[index + 2] == 0xBF { index += 3; skipWhitespace() }
    guard consume(UInt8(ascii: "{")) else { return false }
    skipWhitespace()
    if consume(UInt8(ascii: "}")) { return true }
    while true {
      skipWhitespace()
      guard let key = string() else { return false }
      skipWhitespace()
      guard consume(UInt8(ascii: ":")) else { return false }
      skipWhitespace()
      guard visit(key, &self) else { return false }
      skipWhitespace()
      if consume(UInt8(ascii: ",")) { continue }
      return consume(UInt8(ascii: "}"))
    }
  }

  /// A JSON number at the current position.
  mutating func number() -> Double? {
    var negative = false
    if consume(UInt8(ascii: "-")) { negative = true }
    var value = 0.0
    var digits = 0
    while index < bytes.count, let digit = Self.digit(bytes[index]) { value = value * 10 + Double(digit); index += 1; digits += 1 }
    guard digits > 0 else { return nil }
    if consume(UInt8(ascii: ".")) {
      var scale = 0.1
      var fraction = 0
      while index < bytes.count, let digit = Self.digit(bytes[index]) { value += Double(digit) * scale; scale /= 10; index += 1; fraction += 1 }
      guard fraction > 0 else { return nil }
    }
    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
      index += 1
      var exponentNegative = false
      if consume(UInt8(ascii: "-")) { exponentNegative = true } else { _ = consume(UInt8(ascii: "+")) }
      var exponent = 0
      var exponentDigits = 0
      while index < bytes.count, let digit = Self.digit(bytes[index]) { exponent = min(exponent * 10 + digit, 400); index += 1; exponentDigits += 1 }
      guard exponentDigits > 0 else { return nil }
      for _ in 0..<exponent { value = exponentNegative ? value / 10 : value * 10 }
    }
    return negative ? -value : value
  }

  /// Moves past the value at the current position (any JSON value, nested ones included).
  mutating func skipValue() -> Bool {
    skipWhitespace()
    guard index < bytes.count else { return false }
    switch bytes[index] {
    case UInt8(ascii: "\""):
      return string() != nil
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      var depth = 0
      while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "\""):
          guard string() != nil else { return false }
          continue
        case UInt8(ascii: "{"), UInt8(ascii: "["):
          depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          depth -= 1
          if depth == 0 { index += 1; return true }
        default:
          break
        }
        index += 1
      }
      return false
    default:
      // A number, true, false or null: up to the next delimiter.
      let start = index
      while index < bytes.count {
        let byte = bytes[index]
        if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") || Self.isWhitespace(byte) { break }
        index += 1
      }
      return index > start
    }
  }

  /// The string at the current position, its escapes kept as written (the keys this reads have none).
  private mutating func string() -> String? {
    guard consume(UInt8(ascii: "\"")) else { return nil }
    let start = index
    while index < bytes.count {
      let byte = bytes[index]
      if byte == UInt8(ascii: "\\") { index += 2; continue }
      if byte == UInt8(ascii: "\"") {
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        index += 1
        return text
      }
      index += 1
    }
    return nil
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }

  private static func digit(_ byte: UInt8) -> Int? {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") ? Int(byte - UInt8(ascii: "0")) : nil
  }
}
