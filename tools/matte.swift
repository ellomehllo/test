// matte.swift — background removal + seamless loop for the Vanar Sathi character clips.
// usage: matte <input.mp4|png> <outDir> [--scale 0.5] [--height 720] [--xfade 12] [--start 0] [--end -1]
// Writes outDir/f_%04d.png (RGBA, unpremultiplied) and outDir/report.json.
import Foundation
import AVFoundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

var args = CommandLine.arguments.dropFirst().map { $0 }
func opt(_ k: String, _ d: Double) -> Double { if let i = args.firstIndex(of: k), i + 1 < args.count { return Double(args[i + 1]) ?? d }; return d }
let input = args[0], outDir = args[1]
let scale = opt("--scale", 0.5), outH = Int(opt("--height", 720)), xfade = Int(opt("--xfade", 12))
let glowLo = Float(opt("--glow", 228)), simpleMode = args.contains("--simple")
let startF = Int(opt("--start", 0)), endF = Int(opt("--end", -1))
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct Img { var w: Int; var h: Int; var px: [UInt8] }   // RGBA8

func toImg(_ cg: CGImage) -> Img {
  let w = cg.width, h = cg.height
  var px = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  return Img(w: w, h: h, px: px)
}
func toCG(_ im: Img, alpha: Bool) -> CGImage {
  var px = im.px
  let info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
  let prov = CGDataProvider(data: Data(bytes: &px, count: px.count) as CFData)!
  return CGImage(width: im.w, height: im.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: im.w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}
func savePNG(_ cg: CGImage, _ path: String) {
  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}

// ── 1. read frames (downscaled to the working resolution) ──
var frames: [Img] = []
let ciCtx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
func scaled(_ ci: CIImage) -> CGImage {
  let s = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  let r = CGRect(x: 0, y: 0, width: floor(s.extent.width), height: floor(s.extent.height))
  return ciCtx.createCGImage(s, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
}
if input.lowercased().hasSuffix(".png") || input.lowercased().hasSuffix(".jpg") {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil)!
  frames.append(toImg(scaled(CIImage(cgImage: CGImageSourceCreateImageAtIndex(src, 0, nil)!))))
} else {
  let asset = AVURLAsset(url: URL(fileURLWithPath: input))
  let sem = DispatchSemaphore(value: 0); var track: AVAssetTrack!
  Task { track = try! await asset.loadTracks(withMediaType: .video).first!; sem.signal() }; sem.wait()
  let reader = try! AVAssetReader(asset: asset)
  let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(out); reader.startReading()
  var i = 0
  while let sb = out.copyNextSampleBuffer() {
    defer { i += 1 }
    if i < startF || (endF >= 0 && i > endF) { continue }
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    frames.append(toImg(scaled(CIImage(cvPixelBuffer: pb))))
  }
}
let W = frames[0].w, H = frames[0].h, N = frames.count
FileHandle.standardError.write("frames \(N) at \(W)x\(H)\n".data(using: .utf8)!)

if args.contains("--analyze") {
  // grayscale 1/6 thumbnails, all-pairs mean abs diff → best loop windows
  let st = 6, tw0 = W / st, th0 = H / st
  let g: [[Float]] = frames.map { f in var o = [Float](repeating: 0, count: tw0 * th0)
    for y in 0..<th0 { for x in 0..<tw0 { let k = (y * st * W + x * st) * 4; o[y * tw0 + x] = (Float(f.px[k]) + Float(f.px[k + 1]) + Float(f.px[k + 2])) / 765 } }; return o }
  func d(_ a: Int, _ b: Int) -> Float { var s: Float = 0; for k in 0..<g[a].count { s += abs(g[a][k] - g[b][k]) }; return s / Float(g[a].count) }
  var cons: Float = 0; for i in 1..<N { cons += d(i - 1, i) }; cons /= Float(N - 1)
  var best: [(Float, Int, Int)] = []
  for s0 in 0..<(N / 3) { for e in stride(from: N - 1, to: s0 + N / 2, by: -1) { best.append((d(s0, e), s0, e)) } }
  best.sort { $0.0 < $1.0 }
  print("consecutive \(cons)  first-last \(d(0, N - 1))")
  for b in best.prefix(6) { print(String(format: "diff %.5f  start %d end %d len %d", b.0, b.1, b.2, b.2 - b.1)) }
  exit(0)
}
// ── 2. Vision foreground masks ──
var masks: [[Float]] = []
for f in frames {
  let cg = toCG(f, alpha: false)
  let req = VNGenerateForegroundInstanceMaskRequest()
  let h = VNImageRequestHandler(cgImage: cg)
  try! h.perform([req])
  var m = [Float](repeating: 0, count: W * H)
  if let r = req.results?.first {
    let pb = try! r.generateScaledMaskForImage(forInstances: r.allInstances, from: h)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float.self)
    let rowF = CVPixelBufferGetBytesPerRow(pb) / 4
    for y in 0..<H { for x in 0..<W { m[y * W + x] = base[y * rowF + x] } }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
  }
  masks.append(m)
}
// temporal smoothing of the coarse mask (.25 .5 .25) — steadies the edge band between frames
if N > 2 {
  let orig = masks
  for i in 0..<N {
    let a = orig[max(0, i - 1)], b = orig[i], c = orig[min(N - 1, i + 1)]
    for k in 0..<(W * H) { masks[i][k] = 0.25 * a[k] + 0.5 * b[k] + 0.25 * c[k] }
  }
}

// separable box min/max on a binary map
func morph(_ src: [UInt8], _ r: Int, dilate: Bool) -> [UInt8] {
  var tmp = src, out = src
  for y in 0..<H { for x in 0..<W {
    var v: UInt8 = dilate ? 0 : 1
    for dx in -r...r { let xx = min(W - 1, max(0, x + dx)); let s = src[y * W + xx]; if dilate { v = max(v, s) } else { v = min(v, s) } }
    tmp[y * W + x] = v } }
  for y in 0..<H { for x in 0..<W {
    var v: UInt8 = dilate ? 0 : 1
    for dy in -r...r { let yy = min(H - 1, max(0, y + dy)); let s = tmp[yy * W + x]; if dilate { v = max(v, s) } else { v = min(v, s) } }
    out[y * W + x] = v } }
  return out
}

// push-pull fill: colours known where wt>0, holes filled smoothly from the surroundings
func pushPull(_ col: [Float], _ wt: [Float], _ w: Int, _ h: Int) -> [Float] {
  if w <= 1 || h <= 1 { return col }
  let w2 = (w + 1) / 2, h2 = (h + 1) / 2
  var c2 = [Float](repeating: 0, count: w2 * h2 * 3), wt2 = [Float](repeating: 0, count: w2 * h2)
  for y in 0..<h { for x in 0..<w {
    let k = y * w + x, k2 = (y / 2) * w2 + x / 2, ww = wt[k]
    wt2[k2] += ww; for c in 0..<3 { c2[k2 * 3 + c] += col[k * 3 + c] * ww } } }
  for k in 0..<(w2 * h2) where wt2[k] > 0 { for c in 0..<3 { c2[k * 3 + c] /= wt2[k] }; wt2[k] = min(1, wt2[k]) }
  let coarse = pushPull(c2, wt2, w2, h2)
  var out = col
  for y in 0..<h { for x in 0..<w {
    let k = y * w + x, k2 = (y / 2) * w2 + x / 2, ww = min(1, wt[k])
    for c in 0..<3 { out[k * 3 + c] = col[k * 3 + c] * ww + coarse[k2 * 3 + c] * (1 - ww) } } }
  return out
}
// chamfer distance (px) from each inside pixel to the nearest outside pixel
func distIn(_ bin: [UInt8]) -> [Float] {
  var d = bin.map { $0 == 1 ? Float(1e6) : 0 }
  for y in 0..<H { for x in 0..<W { let k = y * W + x; if d[k] > 0 { d[k] = Float(min(min(x, W - 1 - x), min(y, H - 1 - y)) + 1) } } }
  for y in 0..<H { for x in 0..<W { let k = y * W + x; if d[k] == 0 { continue }
    if x > 0 { d[k] = min(d[k], d[k - 1] + 1) }; if y > 0 { d[k] = min(d[k], d[k - W] + 1) }
    if x > 0 && y > 0 { d[k] = min(d[k], d[k - W - 1] + 1.414) }; if x < W - 1 && y > 0 { d[k] = min(d[k], d[k - W + 1] + 1.414) } } }
  for y in stride(from: H - 1, through: 0, by: -1) { for x in stride(from: W - 1, through: 0, by: -1) { let k = y * W + x; if d[k] == 0 { continue }
    if x < W - 1 { d[k] = min(d[k], d[k + 1] + 1) }; if y < H - 1 { d[k] = min(d[k], d[k + W] + 1) }
    if x < W - 1 && y < H - 1 { d[k] = min(d[k], d[k + W + 1] + 1.414) }; if x > 0 && y < H - 1 { d[k] = min(d[k], d[k + W - 1] + 1.414) } } }
  return d
}
func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }

// ── 3. per-frame matte ──
let rIn = max(2, Int(6 * scale / 0.5)), rOut = max(4, Int(12 * scale / 0.5)), rPlate = max(6, Int(18 * scale / 0.5))
var rgba: [[Float]] = []   // premultiplied RGBA floats 0..1
var coverage: [Double] = []
for i in 0..<N {
  let f = frames[i], m = masks[i]
  let bin = m.map { $0 > 0.5 ? UInt8(1) : 0 }
  let dIn = distIn(bin), band = Float(opt("--band", 30) * scale / 0.5)
  let inner = morph(bin, rIn, dilate: false), outer = morph(bin, rOut, dilate: true), plateHole = morph(bin, rPlate, dilate: true)
  // background plate: the frame itself with the figure (plus margin) removed and filled in
  var col = [Float](repeating: 0, count: W * H * 3), wt = [Float](repeating: 0, count: W * H)
  for k in 0..<(W * H) { for c in 0..<3 { col[k * 3 + c] = Float(f.px[k * 4 + c]) }; wt[k] = plateHole[k] == 1 ? 0 : 1 }
  let plate = pushPull(col, wt, W, H)
  // local texture (std of luma, 7x7) — enclosed background and glow are smooth, real detail is not
  var lum = [Double](repeating: 0, count: W * H)
  for k in 0..<(W * H) { lum[k] = 0.299 * Double(f.px[k * 4]) + 0.587 * Double(f.px[k * 4 + 1]) + 0.114 * Double(f.px[k * 4 + 2]) }
  var I1 = [Double](repeating: 0, count: (W + 1) * (H + 1)), I2 = I1
  for y in 0..<H { var r1 = 0.0, r2 = 0.0; for x in 0..<W { r1 += lum[y * W + x]; r2 += lum[y * W + x] * lum[y * W + x]
    I1[(y + 1) * (W + 1) + x + 1] = I1[y * (W + 1) + x + 1] + r1; I2[(y + 1) * (W + 1) + x + 1] = I2[y * (W + 1) + x + 1] + r2 } }
  let R = 3
  func lstd(_ x: Int, _ y: Int) -> Float {
    let xa = max(0, x - R), xb = min(W, x + R + 1), ya = max(0, y - R), yb = min(H, y + R + 1), n = Double((xb - xa) * (yb - ya))
    let s1 = I1[yb * (W + 1) + xb] - I1[ya * (W + 1) + xb] - I1[yb * (W + 1) + xa] + I1[ya * (W + 1) + xa]
    let s2 = I2[yb * (W + 1) + xb] - I2[ya * (W + 1) + xb] - I2[yb * (W + 1) + xa] + I2[ya * (W + 1) + xa]
    return Float(max(0, s2 / n - (s1 / n) * (s1 / n)).squareRoot())
  }
  var bg: (Float, Float, Float) = (0, 0, 0); var bn: Float = 0
  for k in stride(from: 0, to: W * H, by: 3) where plateHole[k] == 0 { bg.0 += Float(f.px[k * 4]); bg.1 += Float(f.px[k * 4 + 1]); bg.2 += Float(f.px[k * 4 + 2]); bn += 1 }
  if bn > 0 { bg = (bg.0 / bn, bg.1 / bn, bg.2 / bn) }
  // bg-likeness: smooth AND (close to the background colour OR a warm bright glow); only large regions count
  var bgLike = [Float](repeating: 0, count: W * H), glowLike = bgLike
  for k in 0..<(W * H) where outer[k] == 1 {
    let y = k / W, x = k % W
    let sm = 1 - smoothstep(2.5, 7, lstd(x, y))
    if sm <= 0 { continue }
    let r = Float(f.px[k * 4]), g = Float(f.px[k * 4 + 1]), b = Float(f.px[k * 4 + 2])
    let dr = r - bg.0, dg = g - bg.1, db = b - bg.2
    let close = 1 - smoothstep(12, 28, (dr * dr + dg * dg + db * db).squareRoot())
    let warm = smoothstep(8, 22, r - b) * (g >= b ? 1 : 0)
    let glow = smoothstep(glowLo, glowLo + 14, Float(lum[k])) * warm
    bgLike[k] = sm * close; glowLike[k] = sm * glow
    if simpleMode { bgLike[k] = sm * max(close, smoothstep(208, 228, Float(lum[k]))) }
  }
  // glow only counts where it connects to the real outside through other glow pixels (halo, not a skin highlight)
  var reach = [UInt8](repeating: 0, count: W * H); var queue: [Int] = []
  for k in 0..<(W * H) where bin[k] == 0 && outer[k] == 1 { reach[k] = 1; queue.append(k) }
  var qi = 0
  while qi < queue.count { let k = queue[qi]; qi += 1; let x = k % W, y = k / W
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { let xx = x + dx, yy = y + dy
      if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
      if reach[n] == 0 && bin[n] == 1 && glowLike[n] > 0.5 { reach[n] = 1; queue.append(n) } } }
  var glowFinal = [Float](repeating: 0, count: W * H)
  let glowAny = args.contains("--glowany")
  for k in 0..<(W * H) where (glowAny || reach[k] == 1) && bin[k] == 1 { glowFinal[k] = glowLike[k] }
  let rOpen = max(3, Int(5 * scale / 0.6))
  let bgOpen = morph(morph(bgLike.map { $0 > 0.5 ? UInt8(1) : 0 }, rOpen, dilate: false), rOpen + 1, dilate: true)
  let bgOpenS = simpleMode ? morph(morph(bgLike.map { $0 > 0.35 ? UInt8(1) : 0 }, 3, dilate: false), 6, dilate: true) : bgOpen
  var o = [Float](repeating: 0, count: W * H * 4); var cov = 0.0
  for k in 0..<(W * H) {
    var a: Float = 0
    if inner[k] == 1 && dIn[k] > band { a = 1 }
    else if outer[k] == 1 {
      let dr = Float(f.px[k * 4]) - plate[k * 3], dg = Float(f.px[k * 4 + 1]) - plate[k * 3 + 1], db = Float(f.px[k * 4 + 2]) - plate[k * 3 + 2]
      let d = (0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db).squareRoot() + abs(dr - db) * 0.35  // luma + warmth difference
      let deep = inner[k] == 1 ? smoothstep(band * 0.55, band, dIn[k]) : 0
      a = inner[k] == 1 ? max(smoothstep(9, 38, d), deep) : max(smoothstep(9, 38, d), smoothstep(0.55, 0.97, m[k]) * smoothstep(10, 24, d))
    }
    if a > 0 {
      if simpleMode {   // v2 rule: smooth AND (background-coloured OR bright); small spots (tilak) survive
        if bgOpenS[k] == 1 { a *= 1 - bgLike[k] }
      } else { a *= 1 - max(bgOpen[k] == 1 ? bgLike[k] : 0, glowFinal[k]) }
    }
    // haze: semi-transparent AND texture-less is glow or cloud, not hair or an anti-aliased edge
    if a > 0 && a < 0.9 { let st = lstd(k % W, k / W); if st < 5 { a *= smoothstep(0.35, 0.9, a) + (1 - smoothstep(0.35, 0.9, a)) * smoothstep(2.5, 5, st) } }
    if a < 0.02 { a = 0 }
    // colour decontamination: remove the cream background that bleeds into soft edges
    for c in 0..<3 {
      let C = Float(f.px[k * 4 + c]) / 255, B = plate[k * 3 + c] / 255
      let F = a > 0 ? min(1, max(0, B + (C - B) / max(a, 0.12))) : 0
      o[k * 4 + c] = F * a
    }
    o[k * 4 + 3] = a; cov += Double(a)
  }
  // keep only the figure: drop detached specks (watermark, shadow lines, stray glow) smaller than 3% of the largest part
  var lab = [Int32](repeating: -1, count: W * H); var areas: [Int] = []
  for k0 in 0..<(W * H) where lab[k0] < 0 && o[k0 * 4 + 3] > 0.04 {
    let id = Int32(areas.count); var q = [k0]; lab[k0] = id; var qi = 0
    while qi < q.count { let k = q[qi]; qi += 1; let x = k % W, y = k / W
      for dy in -1...1 { for dx in -1...1 { let xx = x + dx, yy = y + dy
        if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
        if lab[n] < 0 && o[n * 4 + 3] > 0.04 { lab[n] = id; q.append(n) } } } }
    areas.append(q.count)
  }
  let big = areas.max() ?? 0
  cov = 0
  for k in 0..<(W * H) {
    let keep = lab[k] >= 0 && Double(areas[Int(lab[k])]) >= Double(big) * 0.03
    if !keep { o[k * 4] = 0; o[k * 4 + 1] = 0; o[k * 4 + 2] = 0; o[k * 4 + 3] = 0 } else { cov += Double(o[k * 4 + 3]) }
  }
  rgba.append(o); coverage.append(cov / Double(W * H))
}

// ── 4. loop: cross-fade the tail into the head so the last frame flows into the first ──
func diff(_ a: [Float], _ b: [Float]) -> Double { var s = 0.0; for k in stride(from: 0, to: a.count, by: 4) { s += Double(abs(a[k] - b[k]) + abs(a[k + 1] - b[k + 1]) + abs(a[k + 2] - b[k + 2]) + abs(a[k + 3] - b[k + 3])) }; return s / Double(a.count) }
var consec: [Double] = []
for i in 1..<max(2, N) where N > 1 { consec.append(diff(rgba[i - 1], rgba[i])) }
let meanConsec = consec.isEmpty ? 0 : consec.reduce(0, +) / Double(consec.count)
let seamBefore = N > 1 ? diff(rgba[N - 1], rgba[0]) : 0
var outFrames = rgba
let K = min(xfade, N / 3)
let pingpong = args.contains("--pingpong")
if pingpong && N > 3 {
  // forward then backward without repeating the end frames: 0…N-1…1
  outFrames = rgba + rgba[1..<(N - 1)].reversed()
} else if N > 3 && K > 0 {
  // output length N-K: frame j<K = blend(tail frame N-K+j, head frame j)
  outFrames = []
  for j in 0..<(N - K) {
    if j < K {
      let t = Float(j + 1) / Float(K + 1), A = rgba[N - K + j], B = rgba[j]
      var o = A; for k in 0..<o.count { o[k] = A[k] * (1 - t) + B[k] * t }
      outFrames.append(o)
    } else { outFrames.append(rgba[j]) }
  }
}
let NO = outFrames.count
let seamAfter = NO > 1 ? diff(outFrames[NO - 1], outFrames[0]) : 0

// ── 5. crop to the union of the figure over all frames, scale, write ──
var x0 = W, y0 = H, x1 = 0, y1 = 0
for o in outFrames { for y in 0..<H { for x in 0..<W where o[(y * W + x) * 4 + 3] > 0.03 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } } }
let pad = Int(Double(max(x1 - x0, y1 - y0)) * 0.03)
x0 = max(0, x0 - pad); y0 = max(0, y0 - pad); x1 = min(W - 1, x1 + pad); y1 = min(H - 1, y1 + pad)
let cw = x1 - x0 + 1, ch = y1 - y0 + 1
let th = min(outH, Int(Double(ch) / scale)), tw = (Int(Double(cw) * Double(th) / Double(ch)) / 2) * 2
let thE = (th / 2) * 2
var alphaStats: [[Double]] = []
for (j, o) in outFrames.enumerated() {
  var c = Img(w: cw, h: ch, px: [UInt8](repeating: 0, count: cw * ch * 4))
  var semi = 0, opaque = 0
  for y in 0..<ch { for x in 0..<cw {
    let k = ((y + y0) * W + (x + x0)) * 4, q = (y * cw + x) * 4, a = o[k + 3]
    c.px[q + 3] = UInt8(min(255, max(0, a * 255 + 0.5)))
    for cc in 0..<3 { c.px[q + cc] = UInt8(min(255, max(0, (a > 0 ? o[k + cc] / a : 0) * 255 + 0.5))) }
    if a > 0.02 && a < 0.98 { semi += 1 } else if a >= 0.98 { opaque += 1 }
  } }
  alphaStats.append([Double(opaque), Double(semi)])
  // scale with CoreImage (premultiply first so edges don't pick up black)
  let ci = CIImage(cgImage: toCG(c, alpha: true)).premultiplyingAlpha()
  let sx = Double(tw) / Double(cw), sy = Double(thE) / Double(ch)
  let s = ci.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": sy, "inputAspectRatio": sx / sy]).unpremultiplyingAlpha()
  let cg = ciCtx.createCGImage(s, from: CGRect(x: 0, y: 0, width: tw, height: thE), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
  savePNG(cg, "\(outDir)/f_\(String(format: "%04d", j)).png")
}
let rep: [String: Any] = ["frames_in": N, "frames_out": NO, "xfade": pingpong ? 0 : K, "pingpong": pingpong, "work": [W, H], "crop": [x0, y0, cw, ch], "out": [tw, thE],
  "mean_consecutive_diff": meanConsec, "seam_diff_before": seamBefore, "seam_diff_after": seamAfter,
  "coverage_min": coverage.min() ?? 0, "coverage_max": coverage.max() ?? 0,
  "opaque_px_min": alphaStats.map { $0[0] }.min() ?? 0, "opaque_px_max": alphaStats.map { $0[0] }.max() ?? 0,
  "semi_px_min": alphaStats.map { $0[1] }.min() ?? 0, "semi_px_max": alphaStats.map { $0[1] }.max() ?? 0]
let js = try! JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys])
try! js.write(to: URL(fileURLWithPath: "\(outDir)/report.json"))
print(String(data: js, encoding: .utf8)!)
