import SwiftUI
import SwiftUIWebBrowser
import SkipMotion

/// The fixture for `Web/demo/test-browser.mjs`: one `MotionView` over a small Lottie animation and one button per
/// playback the test asks for. The animation is 100 by 100 points, 60 frames at 30 fps: a square whose centre moves
/// from x = 20 at frame 0 to x = 80 at frame 60, so the test reads where lottie-web stands from the square's transform.
/// Every `onComplete` goes to the `log` text as one line, `C|<finished>`.
@Observable @MainActor final class MotionDemoModel {
  var lines: [String] = []
  var loopMode: MotionLoopMode = .loop
  var isPlaying = true
  var speed = 1.0
  var contentMode: MotionContentMode = .fit
  var progress: Double?
  var frame: CGFloat?
  var from: Double?
  var to: Double?
  var showsView = true

  func play(_ mode: MotionLoopMode, speed: Double = 1, from: Double? = nil, to: Double? = nil) {
    loopMode = mode
    self.speed = speed
    self.from = from
    self.to = to
    progress = nil
    frame = nil
    isPlaying = true
  }

  func pause(progress: Double? = nil, frame: CGFloat? = nil) {
    self.progress = progress
    self.frame = frame
    isPlaying = false
  }
}

let probeAnimation = """
{"v":"5.7.4","fr":30,"ip":0,"op":60,"w":100,"h":100,"nm":"probe","ddd":0,"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,\
"nm":"square","sr":1,"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":1,"k":[{"t":0,"s":[20,50,0],\
"i":{"x":[1],"y":[1]},"o":{"x":[0],"y":[0]}},{"t":60,"s":[80,50,0]}]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},\
"ao":0,"shapes":[{"ty":"gr","nm":"box","it":[{"ty":"rc","d":1,"nm":"rect","s":{"a":0,"k":[20,20]},"p":{"a":0,"k":[0,0]},\
"r":{"a":0,"k":0}},{"ty":"fl","nm":"fill","c":{"a":0,"k":[1,0.4,0,1]},"o":{"a":0,"k":100},"r":1},{"ty":"tr","p":{"a":0,"k":[0,0]},\
"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100},"sk":{"a":0,"k":0},"sa":{"a":0,"k":0}}]}],\
"ip":0,"op":60,"st":0,"bm":0}],"markers":[]}
"""

/// `probeAnimation` with its manifest in a dotLottie archive (`zip -9`), in base 64: the container reads the same header.
let probeDotLottie = "UEsDBBQAAgAIAIWCdV3+1cxvLwAAADAAAAANAAAAbWFuaWZlc3QuanNvbqtWKkstKs7Mz1OyUjLUM9AzUNJRSszLzE0sAYoVK1lFVytlpgDlchMz85RqY2sBUEsDBBQAAgAIAIWCdV2p1wvqKAEAAAADAAAUAAAAYW5pbWF0aW9ucy9tYWluLmpzb25tUtuSgjAM/Zc8d5jiorvTX3F4KLeVASzbdlcZhn83CVVX6YOecpKc5KSd4Q8U7JPPJAMBjQX1IQW0IygEg3BAvIBKJeIp4HnAmtGaosaaqqo4WTtXewfqmAvo9VRbOs+PcHtGTAX4CVQWJNzPr7ak4SzHOiyZwdCf5qKOGy4C7AtHzBiYlBls5DlKTXdS7KWQOEdLSVekUvyYGLHU3FkZWJkvi2CFQ5D4ChIL5euX5kfkKcKJ/3laTfiRHmizTnTSY73ugrzDt4VgvzBXPLb+GbMlLZRNcYatSw+bRuhvxwOMm8HyyK7YGqk3/b1z0/Z0Lt8MCJlkaO65pO0tpA81Tz7iE+goG19XHr3dWHfXbdKcfveKN7Z5vm59GsVAGRgetO3W55kvN1BLAQIeAxQAAgAIAIWCdV3+1cxvLwAAADAAAAANAAAAAAAAAAEAAACkgQAAAABtYW5pZmVzdC5qc29uUEsBAh4DFAACAAgAhYJ1XanXC+ooAQAAAAMAABQAAAAAAAAAAQAAAKSBWgAAAGFuaW1hdGlvbnMvbWFpbi5qc29uUEsFBgAAAAACAAIAfQAAALQBAAAAAA=="

private struct MotionDemoRoot: View {
  @State private var model = MotionDemoModel()
  private let container = try? LottieContainer(data: Data(probeAnimation.utf8))
  private let archived = Data(base64Encoded: probeDotLottie).flatMap { try? LottieContainer(data: $0) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.showsView, let container {
        MotionView(
          lottie: container, animationSpeed: model.speed, loopMode: model.loopMode, isPlaying: model.isPlaying,
          contentMode: model.contentMode, currentProgress: model.progress, fromProgress: model.from, toProgress: model.to,
          currentFrame: model.frame, onComplete: { finished in model.lines.append("C|\(finished)") }
        )
        .frame(width: 200, height: 200)
        .accessibilityIdentifier("motion")
      }
      HStack {
        Button("loop") { model.play(.loop) }.accessibilityIdentifier("loop")
        Button("once") { model.play(.playOnce) }.accessibilityIdentifier("once")
        Button("once-fast") { model.play(.playOnce, speed: 4) }.accessibilityIdentifier("once-fast")
        Button("repeat2") { model.play(.repeat(2), speed: 4) }.accessibilityIdentifier("repeat2")
        Button("range") { model.play(.playOnce, from: 0.5, to: 0.75) }.accessibilityIdentifier("range")
        Button("autoreverse") { model.play(.autoReverse, speed: 4) }.accessibilityIdentifier("autoreverse")
      }
      HStack {
        Button("pause") { model.pause() }.accessibilityIdentifier("pause")
        Button("pause-half") { model.pause(progress: 0.5) }.accessibilityIdentifier("pause-half")
        Button("frame-15") { model.pause(frame: 15) }.accessibilityIdentifier("frame-15")
        Button("fill") { model.contentMode = .fill }.accessibilityIdentifier("fill")
        Button("hide") { model.showsView = false }.accessibilityIdentifier("hide")
        Button("show") { model.showsView = true }.accessibilityIdentifier("show")
      }
      // What the container read from the header, so the test checks the Swift side too.
      if let container {
        Text("H|\(container.duration)|\(container.startFrame)|\(container.endFrame)|\(container.framerate)|\(container.width)|\(container.height)")
          .accessibilityIdentifier("header")
      }
      if let archived {
        Text("D|\(archived.duration)|\(archived.startFrame)|\(archived.endFrame)|\(archived.framerate)|\(archived.width)|\(archived.height)")
          .accessibilityIdentifier("archived")
      }
      Text(model.lines.joined(separator: "\n")).accessibilityIdentifier("log")
    }
    .padding()
  }
}

@main
private struct MotionDemoApp: BrowserApp {
  var body: some View {
    WindowGroup { MotionDemoRoot() }
  }
}
