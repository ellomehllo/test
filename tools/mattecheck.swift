// mattecheck.swift — numbers for the problems you see on a dark background, per frame of a matted clip.
//   fringe  pale half-transparent pixels near the silhouette (cream background bleeding into the edge), weighted by
//           opacity: they read as a white outline / white patches in gaps on a dark backdrop. Per mille of figure area.
//   halo    half-transparent pixels (8–90 % opacity) in general, per mille of figure area: a wide soft ring.
//   flick   mean change of opacity from the previous frame where the colour hardly changed (unjustified flicker).
//   top     top edge of the figure, to see where in the loop the figure rises and sinks.
//   region  share of opaque pixels inside an optional box (e.g. the tail), to see a limb fading out.
// usage: swift mattecheck.swift <dir of f_NNNN.png> [--box x0 y0 x1 y1 (fractions)] [--every N] [--map N out.png]
//   --map writes frame N over a dark backdrop with the fringe pixels painted red, to see where they are.
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
let dir = args[1]
func opt(_ k: String) -> [Double]? {
  guard let i = args.firstIndex(of: k) else { return nil }
  return args[(i + 1)...].prefix(while: { Double($0) != nil }).compactMap(Double.init)
}
let box = opt("--box"), every = Int(opt("--every")?.first ?? 1)
let files = (try! FileManager.default.contentsOfDirectory(atPath: dir)).filter { $0.hasPrefix("f_") && $0.hasSuffix(".png") }.sorted()

func load(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let w = img.width, h = img.height
  var px = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  return (w, h, px)
}

if let i = args.firstIndex(of: "--map"), i + 2 < args.count, let n = Int(args[i + 1]) {
  var (w, h, px) = load("\(dir)/\(files[n])")
  var o = [UInt8](repeating: 255, count: w * h * 4)
  for k in stride(from: 0, to: px.count, by: 4) {
    let a = Int(px[k + 3]), bg: [Double] = [13, 38, 32]
    var c = (0..<3).map { Double(px[k + $0]) + bg[$0] * (1 - Double(a) / 255) }   // premultiplied over the app's dark green
    if a > 20 && a < 230 {
      let r = Double(px[k]) * 255 / Double(a), g = Double(px[k + 1]) * 255 / Double(a), b = Double(px[k + 2]) * 255 / Double(a)
      if 0.299 * r + 0.587 * g + 0.114 * b > 190 && max(r, g, b) - min(r, g, b) < 70 { c = [255, 0, 0] }
    }
    for j in 0..<3 { o[k + j] = UInt8(min(255, max(0, c[j]))) }
  }
  let prov = CGDataProvider(data: Data(bytes: &o, count: o.count) as CFData)!
  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[i + 2]) as CFURL, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
  _ = px; exit(0)
}
print("frame  fringe‰  halo‰  flick   top  region")
var prev: [UInt8] = []
var tot = (fr: 0.0, ha: 0.0, fl: 0.0, n: 0)
for (i, name) in files.enumerated() where i % every == 0 || every == 1 {
  let (w, h, px) = load("\(dir)/\(name)")
  var area = 0, fringe = 0.0, halo = 0, top = h, inBox = 0, boxN = 0
  var fl = 0.0
  let bx = box.map { (Int($0[0] * Double(w)), Int($0[1] * Double(h)), Int($0[2] * Double(w)), Int($0[3] * Double(h))) }
  for y in 0..<h { for x in 0..<w {
    let k = (y * w + x) * 4, a = Int(px[k + 3])
    if a > 128 { area += 1; top = min(top, y) }
    if a > 20 && a < 230 {
      halo += 1
      // un-premultiply to see the colour this pixel really adds
      let r = Double(px[k]) * 255 / Double(a), g = Double(px[k + 1]) * 255 / Double(a), b = Double(px[k + 2]) * 255 / Double(a)
      let L = 0.299 * r + 0.587 * g + 0.114 * b, sat = max(r, g, b) - min(r, g, b)
      if L > 190 && sat < 70 { fringe += Double(a) / 255 }   // weighted by how much of it shows
    }
    if let (x0, y0, x1, y1) = bx, x >= x0, x < x1, y >= y0, y < y1 { boxN += 1; if a > 128 { inBox += 1 } }
    if !prev.isEmpty {
      let d = abs(a - Int(prev[k + 3]))
      if d > 0 {
        let dc = abs(Int(px[k]) - Int(prev[k])) + abs(Int(px[k + 1]) - Int(prev[k + 1])) + abs(Int(px[k + 2]) - Int(prev[k + 2]))
        if dc < 12 { fl += Double(d) / 255 }   // opacity moved but the picture didn't
      }
    }
  } }
  let fr = fringe / Double(max(1, area)) * 1000, ha = Double(halo) / Double(max(1, area)) * 1000
  let flick = prev.isEmpty ? 0 : fl / Double(w * h) * 1000
  tot.fr += fr; tot.ha += ha; tot.fl += flick; tot.n += 1
  print(String(format: "%5d  %7.2f  %5.1f  %5.3f  %4d  %@", i, fr, ha, flick, top, bx == nil ? "" : String(format: "%.3f", Double(inBox) / Double(max(1, boxN)))))
  prev = px
}
print(String(format: "mean   %7.2f  %5.1f  %5.3f", tot.fr / Double(tot.n), tot.ha / Double(tot.n), tot.fl / Double(max(1, tot.n - 1))))
