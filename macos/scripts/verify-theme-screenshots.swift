// Compare encoded pixels in the PNG's actual ICC color space (Display P3 on this Mac).
// NSBitmapImageRep.colorAt labels bytes as calibrated RGB; do not convert that label.
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let paletteURL = URL(fileURLWithPath: CommandLine.arguments[2])
let palettes = try! JSONSerialization.jsonObject(with: Data(contentsOf: paletteURL)) as! [String: [String: [String: String]]]
var checks: [[String: Any]] = []
for theme in ["blue", "green", "purple", "yellow"] {
 for mode in ["light", "dark"] {
  for page in ["settings", "permissions", "platforms", "recording-settings", "subtitle", "recording", "services", "import", "editor", "floating", "quick-settings", "source-picker"] {
   let key = "\(theme)-\(mode)-\(page)"
   let image = NSBitmapImageRep(data: try! Data(contentsOf: root.appendingPathComponent(key + ".png")))!
   let pixel = image.colorAt(x: image.pixelsWide - (page == "floating" ? 40 : 12), y: page == "floating" ? image.pixelsHigh / 2 : 12)!
   let hex = palettes[theme]![mode]![page == "floating" ? "surface" : "bg"]!
   let expected = UInt32(hex.dropFirst(), radix: 16)!
   let rgb = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent].map { Int(($0 * 255).rounded()) }
   let source = NSColor(srgbRed: CGFloat((expected >> 16) & 255) / 255, green: CGFloat((expected >> 8) & 255) / 255, blue: CGFloat(expected & 255) / 255, alpha: 1)
   let encoded = source.usingColorSpace(image.colorSpace)!
   let target = [encoded.redComponent, encoded.greenComponent, encoded.blueComponent].map { Int(($0 * 255).rounded()) }
   let passed = zip(rgb,target).allSatisfy { abs($0-$1) <= 3 }
   checks.append(["view":key, "passed":passed, "actual":rgb, "target":hex])
  }
 }
}
for theme in ["blue", "green", "purple", "yellow"] {
 for mode in ["light", "dark"] {
  let key = "\(theme)-\(mode)-subtitle"
  let image = NSBitmapImageRep(data: try! Data(contentsOf: root.appendingPathComponent(key + ".png")))!
  let pixel = image.colorAt(x: Int(Double(image.pixelsWide) * 270 / 1280), y: Int(Double(image.pixelsHigh) * 240 / 840))!
  let hex = palettes[theme]![mode]!["surface"]!
  let expected = UInt32(hex.dropFirst(), radix: 16)!
  let rgb = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent].map { Int(($0 * 255).rounded()) }
  let source = NSColor(srgbRed: CGFloat((expected >> 16) & 255) / 255, green: CGFloat((expected >> 8) & 255) / 255, blue: CGFloat(expected & 255) / 255, alpha: 1)
   let encoded = source.usingColorSpace(image.colorSpace)!
   let target = [encoded.redComponent, encoded.greenComponent, encoded.blueComponent].map { Int(($0 * 255).rounded()) }
  checks.append(["view":key + "-source-card", "passed":zip(rgb,target).allSatisfy { abs($0-$1) <= 3 }, "actual":rgb, "target":hex])
 }
}
let result: [String: Any] = ["passed":checks.allSatisfy { $0["passed"] as! Bool }, "checks":checks]
let data = try! JSONSerialization.data(withJSONObject: result, options:[.prettyPrinted,.sortedKeys])
try! data.write(to:root.deletingLastPathComponent().appendingPathComponent("all-window-pixels.json"))
print("Native surfaces matching approved colors: \(checks.filter { $0["passed"] as! Bool }.count)/\(checks.count)")
for item in checks where !(item["passed"] as! Bool) { print(item) }
