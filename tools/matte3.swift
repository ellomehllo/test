// matte3.swift — hybrid background removal for the Vanar Sathi character clips (v3).
//
//  1. Vision foreground mask per frame, stabilised with a motion-adaptive temporal filter
//     (neighbouring frames only count where the picture itself hasn't changed).
//  2. Halo / glow removal: bright, smooth, background-coloured pixels that connect to the real
//     background are taken out of the mask (a highlight enclosed by skin never is).
//  3. Solid core: everything deeper than `band` px inside the mask is fully opaque — no body patches.
//  4. Edge band: a colour key against a per-frame clean plate (frame with the figure inpainted away)
//     decides softness, so fringes of cream background drop out.
//  5. Enclosed holes are filled unless they really are background (plate colour and smooth).
//  6. Guided filter (image as guide) snaps the matte to true edges with soft, unstepped transitions.
//  7. Motion-adaptive temporal smoothing of the final matte, detached specks removed,
//     edge colours decontaminated against the plate; then loop by cross-fade or ping-pong.
//
// usage: matte3 <input.mp4|png> <outDir> [--scale 0.5] [--height 720] [--start a] [--end b]
//                [--xfade N | --pingpong] [--band 14] [--glow 226] [--analyze]
import Foundation
import AVFoundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ k: String, _ d: Double) -> Double { if let i = args.firstIndex(of: k), i + 1 < args.count { return Double(args[i + 1]) ?? d }; return d }
let input = args[0], outDir = args[1]
let scale = opt("--scale", 0.5), outH = Int(opt("--height", 720)), xfade = Int(opt("--xfade", 0))
let startF = Int(opt("--start", 0)), endF = Int(opt("--end", -1)), pingpong = args.contains("--pingpong")
let glowLo = Float(opt("--glow", 226))
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ciCtx = CIContext(options: [.workingColorSpace: sRGB])
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ───────── frames ─────────
struct Frame { var px: [UInt8] }   // RGBA8 at working resolution
var W = 0, H = 0
func grab(_ ci: CIImage) -> Frame {
  let s = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  let r = CGRect(x: 0, y: 0, width: floor(s.extent.width), height: floor(s.extent.height))
  let cg = ciCtx.createCGImage(s, from: r, format: .RGBA8, colorSpace: sRGB)!
  W = cg.width; H = cg.height
  var px = [UInt8](repeating: 0, count: W * H * 4)
  let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
  return Frame(px: px)
}
var frames: [Frame] = []
if input.lowercased().hasSuffix(".png") || input.lowercased().hasSuffix(".jpg") {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil)!
  frames.append(grab(CIImage(cgImage: CGImageSourceCreateImageAtIndex(src, 0, nil)!)))
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
    if let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(grab(CIImage(cvPixelBuffer: pb))) }
  }
}
let N = frames.count, P = W * H
log("frames \(N) at \(W)x\(H)")
let luma: [[Float]] = frames.map { f in (0..<P).map { k in 0.299 * Float(f.px[k * 4]) + 0.587 * Float(f.px[k * 4 + 1]) + 0.114 * Float(f.px[k * 4 + 2]) } }

if args.contains("--analyze") {
  let st = 6, tw = W / st, th = H / st
  let g = luma.map { l in (0..<(tw * th)).map { i in l[(i / tw) * st * W + (i % tw) * st] / 255 } }
  func d(_ a: Int, _ b: Int) -> Float { var s: Float = 0; for k in 0..<g[a].count { s += abs(g[a][k] - g[b][k]) }; return s / Float(g[a].count) }
  var cons: Float = 0; for i in 1..<N { cons += d(i - 1, i) }; cons /= Float(N - 1)
  var best: [(Float, Int, Int)] = []
  for s0 in 0..<(N / 3) { for e in stride(from: N - 1, to: s0 + N / 2, by: -1) { best.append((d(s0, e), s0, e)) } }
  best.sort { $0.0 < $1.0 }
  print("consecutive \(cons)"); for b in best.prefix(5) { print(String(format: "diff %.5f start %d end %d", b.0, b.1, b.2)) }
  exit(0)
}

// ───────── helpers ─────────
func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
// box mean of a float map (integral image), radius r
func boxMean(_ a: [Float], _ r: Int) -> [Float] {
  var I = [Double](repeating: 0, count: (W + 1) * (H + 1))
  for y in 0..<H { var row = 0.0; for x in 0..<W { row += Double(a[y * W + x]); I[(y + 1) * (W + 1) + x + 1] = I[y * (W + 1) + x + 1] + row } }
  var o = [Float](repeating: 0, count: P)
  for y in 0..<H { let ya = max(0, y - r), yb = min(H, y + r + 1); for x in 0..<W {
    let xa = max(0, x - r), xb = min(W, x + r + 1)
    let s = I[yb * (W + 1) + xb] - I[ya * (W + 1) + xb] - I[yb * (W + 1) + xa] + I[ya * (W + 1) + xa]
    o[y * W + x] = Float(s / Double((xb - xa) * (yb - ya))) } }
  return o
}
// exact-enough Euclidean-ish distance (chamfer 3-4) from every pixel to the nearest pixel where `seed` is true
func distanceTo(_ seed: [Bool], borderIsSeed: Bool) -> [Float] {
  var d = seed.map { $0 ? Float(0) : 1e6 }
  if borderIsSeed { for y in 0..<H { for x in 0..<W { let k = y * W + x; d[k] = min(d[k], Float(min(min(x, W - 1 - x), min(y, H - 1 - y)) + 1)) } } }
  for y in 0..<H { for x in 0..<W { let k = y * W + x; if d[k] == 0 { continue }
    if x > 0 { d[k] = min(d[k], d[k - 1] + 1) }; if y > 0 { d[k] = min(d[k], d[k - W] + 1) }
    if x > 0 && y > 0 { d[k] = min(d[k], d[k - W - 1] + 1.4142) }; if x < W - 1 && y > 0 { d[k] = min(d[k], d[k - W + 1] + 1.4142) } } }
  for y in stride(from: H - 1, through: 0, by: -1) { for x in stride(from: W - 1, through: 0, by: -1) { let k = y * W + x; if d[k] == 0 { continue }
    if x < W - 1 { d[k] = min(d[k], d[k + 1] + 1) }; if y < H - 1 { d[k] = min(d[k], d[k + W] + 1) }
    if x < W - 1 && y < H - 1 { d[k] = min(d[k], d[k + W + 1] + 1.4142) }; if x > 0 && y < H - 1 { d[k] = min(d[k], d[k + W - 1] + 1.4142) } } }
  return d
}
// push–pull inpainting: colours known where wt>0
func pushPull(_ col: [Float], _ wt: [Float], _ w: Int, _ h: Int) -> [Float] {
  if w <= 1 || h <= 1 { return col }
  let w2 = (w + 1) / 2, h2 = (h + 1) / 2
  var c2 = [Float](repeating: 0, count: w2 * h2 * 3), wt2 = [Float](repeating: 0, count: w2 * h2)
  for y in 0..<h { for x in 0..<w { let k = y * w + x, k2 = (y / 2) * w2 + x / 2, ww = wt[k]
    wt2[k2] += ww; for c in 0..<3 { c2[k2 * 3 + c] += col[k * 3 + c] * ww } } }
  for k in 0..<(w2 * h2) where wt2[k] > 0 { for c in 0..<3 { c2[k * 3 + c] /= wt2[k] }; wt2[k] = min(1, wt2[k]) }
  let coarse = pushPull(c2, wt2, w2, h2)
  var out = col
  for y in 0..<h { for x in 0..<w { let k = y * w + x, k2 = (y / 2) * w2 + x / 2, ww = min(1, wt[k])
    for c in 0..<3 { out[k * 3 + c] = col[k * 3 + c] * ww + coarse[k2 * 3 + c] * (1 - ww) } } }
  return out
}
// guided filter (He et al.), grey guide
func guided(_ I: [Float], _ p: [Float], _ r: Int, _ eps: Float) -> [Float] {
  let mI = boxMean(I, r), mp = boxMean(p, r)
  let mIp = boxMean(zip(I, p).map(*), r), mII = boxMean(I.map { $0 * $0 }, r)
  var a = [Float](repeating: 0, count: P), b = a
  for k in 0..<P { let v = mII[k] - mI[k] * mI[k]; a[k] = (mIp[k] - mI[k] * mp[k]) / (v + eps); b[k] = mp[k] - a[k] * mI[k] }
  let ma = boxMean(a, r), mb = boxMean(b, r)
  return (0..<P).map { k in ma[k] * I[k] + mb[k] }
}
// motion-adaptive temporal filter: neighbours weighted by how little the picture changed at that pixel
func temporal(_ maps: [[Float]], radius: Int, sigma: Float) -> [[Float]] {
  if maps.count < 3 { return maps }
  let gw: [Float] = (0...radius).map { exp(-Float($0 * $0) / Float(radius * radius + 1)) }
  var out = maps
  for t in 0..<maps.count {
    var o = [Float](repeating: 0, count: P)
    for k in 0..<P {
      var s: Float = 0, ws: Float = 0
      for j in -radius...radius {
        let u = t + j; if u < 0 || u >= maps.count { continue }
        let dl = (luma[u][k] - luma[t][k]) / sigma
        let w = gw[abs(j)] * exp(-dl * dl)
        s += maps[u][k] * w; ws += w
      }
      o[k] = s / ws
    }
    out[t] = o
  }
  return out
}

// ───────── 1. Vision masks, stabilised ─────────
var masks: [[Float]] = frames.map { f in
  var px = f.px
  let prov = CGDataProvider(data: Data(bytes: &px, count: px.count) as CFData)!
  let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  let req = VNGenerateForegroundInstanceMaskRequest(), h = VNImageRequestHandler(cgImage: cg)
  try! h.perform([req])
  var m = [Float](repeating: 0, count: P)
  if let r = req.results?.first, let pb = try? r.generateScaledMaskForImage(forInstances: r.allInstances, from: h) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float.self), row = CVPixelBufferGetBytesPerRow(pb) / 4
    for y in 0..<H { for x in 0..<W { m[y * W + x] = base[y * row + x] } }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
  }
  return m
}
masks = temporal(masks, radius: 2, sigma: 10)
log("masks done")

// ───────── 2–6. per-frame matte ─────────
let band = Float(opt("--band", 14) * scale / 0.5)
var alphas: [[Float]] = [], plates: [[UInt8]] = []
for t in 0..<N {
  let f = frames[t], L = luma[t]
  var m = masks[t]
  let lum01 = L.map { $0 / 255 }
  let mean = boxMean(lum01, 3), mean2 = boxMean(lum01.map { $0 * $0 }, 3)
  let lstd = (0..<P).map { k in max(0, mean2[k] - mean[k] * mean[k]).squareRoot() * 255 }
  // plate: the frame with the figure (mask + margin) inpainted away
  let outside = distanceTo(m.map { $0 > 0.25 }, borderIsSeed: false)
  var col = [Float](repeating: 0, count: P * 3), wt = [Float](repeating: 0, count: P)
  for k in 0..<P { for c in 0..<3 { col[k * 3 + c] = Float(f.px[k * 4 + c]) }; wt[k] = outside[k] > band * 1.4 ? 1 : 0 }
  let plate = pushPull(col, wt, W, H)
  var bgMean: (Float, Float, Float) = (0, 0, 0); var bn: Float = 0
  for k in stride(from: 0, to: P, by: 5) where wt[k] > 0 { bgMean.0 += plate[k * 3]; bgMean.1 += plate[k * 3 + 1]; bgMean.2 += plate[k * 3 + 2]; bn += 1 }
  if bn > 0 { bgMean = (bgMean.0 / bn, bgMean.1 / bn, bgMean.2 / bn) }
  // colour distance to the plate (luma + warmth), and the colour key from it
  var dist = [Float](repeating: 0, count: P)
  for k in 0..<P {
    let dr = Float(f.px[k * 4]) - plate[k * 3], dg = Float(f.px[k * 4 + 1]) - plate[k * 3 + 1], db = Float(f.px[k * 4 + 2]) - plate[k * 3 + 2]
    dist[k] = (0.3 * dr * dr + 0.59 * dg * dg + 0.11 * db * db).squareRoot() + abs(dr - db) * 0.3
  }
  // 2. halo/glow: smooth + (bright warm, or background-coloured), connected to the outside → not figure
  var glowy = [Bool](repeating: false, count: P)
  for k in 0..<P where m[k] > 0.05 {
    let r = Float(f.px[k * 4]), g = Float(f.px[k * 4 + 1]), b = Float(f.px[k * 4 + 2])
    let smooth = lstd[k] < 5
    let dr = r - bgMean.0, dg = g - bgMean.1, db = b - bgMean.2
    let bgCol = (dr * dr + dg * dg + db * db).squareRoot() < 20
    let warmBright = L[k] > glowLo && r >= g - 4 && g >= b - 4 && dist[k] < 22   // glow is close to the plate; skin is warmer
    glowy[k] = smooth && (bgCol || warmBright)
  }
  var reach = [Bool](repeating: false, count: P); var q: [Int] = []
  for k in 0..<P where m[k] <= 0.05 { reach[k] = true; q.append(k) }
  var qi = 0
  while qi < q.count { let k = q[qi]; qi += 1; let x = k % W, y = k / W
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { let xx = x + dx, yy = y + dy
      if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
      if !reach[n] && glowy[n] { reach[n] = true; q.append(n) } } }
  var removedBg = [Bool](repeating: false, count: P)
  for k in 0..<P where reach[k] && m[k] > 0.05 { m[k] = 0; removedBg[k] = true }
  // enclosed background pockets (between arm and body, behind a bow): smooth and background-coloured or
  // near-white with little saturation, and big enough not to be a highlight
  var pocket = [Bool](repeating: false, count: P)
  // wide-window texture: backlight glow is a perfectly smooth gradient, painted skin never is
  let wmean = boxMean(lum01, 6), wmean2 = boxMean(lum01.map { $0 * $0 }, 6)
  let wstd = (0..<P).map { k in max(0, wmean2[k] - wmean[k] * wmean[k]).squareRoot() * 255 }
  for k in 0..<P where m[k] > 0.05 && lstd[k] < 4 {
    let r = Float(f.px[k * 4]), g = Float(f.px[k * 4 + 1]), b = Float(f.px[k * 4 + 2])
    let dr = r - bgMean.0, dg = g - bgMean.1, db = b - bgMean.2
    let sat = max(r, g, b) - min(r, g, b)
    let warmGlow = L[k] > 196 && r >= g && g >= b && sat < 80 && wstd[k] < 3.2 && lstd[k] < 1.6
    pocket[k] = (dr * dr + dg * dg + db * db).squareRoot() < 18 || (L[k] > 236 && sat < 32) || warmGlow
  }
  if t == 0, let pi = args.firstIndex(of: "--probe") {   // debug: values the pocket test sees around (x,y)
    let px0 = Int(args[pi + 1])!, py0 = Int(args[pi + 2])!
    for dy in stride(from: -20, through: 20, by: 10) { var line = ""
      for dx in stride(from: -20, through: 20, by: 10) { let k = (py0 + dy) * W + px0 + dx
        let r = Int(f.px[k * 4]), g = Int(f.px[k * 4 + 1]), b = Int(f.px[k * 4 + 2])
        line += String(format: "[m%.2f L%3.0f rgb%d,%d,%d s%.1f w%.1f %@] ", m[k], L[k], r, g, b, lstd[k], wstd[k], pocket[k] ? "P" : "-") }
      log(line) }
    log("bg \(bgMean)")
  }
  let minPocket = Int(Float(P) * 0.0004)
  var plab = [Int32](repeating: -1, count: P); var pid: Int32 = 0
  for k0 in 0..<P where pocket[k0] && plab[k0] < 0 {
    var qq = [k0]; plab[k0] = pid; var j = 0
    while j < qq.count { let k = qq[j]; j += 1; let x = k % W, y = k / W
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { let xx = x + dx, yy = y + dy
        if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
        if pocket[n] && plab[n] < 0 { plab[n] = pid; qq.append(n) } } }
    if qq.count >= minPocket { for k in qq { m[k] = 0; removedBg[k] = true } }
    pid += 1
  }
  // 3. solid core / 4. keyed edge band
  let fig = m.map { $0 > 0.5 }
  let dIn = distanceTo(fig.map { !$0 }, borderIsSeed: true)
  var a = [Float](repeating: 0, count: P)
  for k in 0..<P {
    let core = smoothstep(band * 0.5, band, dIn[k])
    let key = smoothstep(5, 24, dist[k])
    let shape = smoothstep(0.15, 0.85, m[k])
    // where Vision is confident the figure stays opaque (skin highlights); the key only shapes the uncertain rim
    a[k] = max(core * (fig[k] ? 1 : 0), shape * max(key, smoothstep(0.85, 0.99, m[k])))
    if !fig[k] && m[k] < 0.15 { a[k] = min(a[k], key * smoothstep(0.02, 0.15, m[k]) * 1.0) }
  }
  // 5. holes: enclosed transparent regions are filled unless they look like real background
  var lab = [Int32](repeating: -1, count: P); var comps: [(touch: Bool, n: Int, bgScore: Float)] = []
  for k0 in 0..<P where lab[k0] < 0 && a[k0] < 0.5 {
    let id = Int32(comps.count); var qq = [k0]; lab[k0] = id; var j = 0; var touch = false; var bgs: Float = 0
    while j < qq.count { let k = qq[j]; j += 1; let x = k % W, y = k / W
      if x == 0 || y == 0 || x == W - 1 || y == H - 1 { touch = true }
      bgs += (masks[t][k] < 0.35 || removedBg[k]) ? 1 : 0     // Vision or the halo/pocket pass called it background
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { let xx = x + dx, yy = y + dy
        if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
        if lab[n] < 0 && a[n] < 0.5 { lab[n] = id; qq.append(n) } } }
    comps.append((touch, qq.count, bgs / Float(qq.count)))
  }
  for k in 0..<P where lab[k] >= 0 {
    let c = comps[Int(lab[k])]
    if !c.touch && c.bgScore < 0.5 { a[k] = 1 }           // a hole our keying made in the body → solid
  }
  // 6. guided filter: edges follow the picture, soft and unstepped
  a = guided(lum01, a, max(2, Int(3 * scale / 0.5)), 0.0008).map { min(1, max(0, $0)) }
  for k in 0..<P where dIn[k] > band && fig[k] { a[k] = 1 }    // core stays solid after filtering
  alphas.append(a)
  var pl = [UInt8](repeating: 0, count: P * 3); for k in 0..<(P * 3) { pl[k] = UInt8(min(255, max(0, plate[k]))) }
  plates.append(pl)
  if t % 20 == 0 { log("frame \(t)") }
}

// ───────── 7. temporal smoothing, specks, decontamination ─────────
alphas = temporal(alphas, radius: 1, sigma: 8)
var rgba: [[Float]] = []
for t in 0..<N {
  var a = alphas[t]
  for k in 0..<P { a[k] = smoothstep(0.04, 0.96, a[k]) }               // tiny choke: no faint fringe ring
  // detached specks (< 3% of the largest part) go
  var lab = [Int32](repeating: -1, count: P); var areas: [Int] = []
  for k0 in 0..<P where lab[k0] < 0 && a[k0] > 0.05 {
    let id = Int32(areas.count); var q = [k0]; lab[k0] = id; var j = 0
    while j < q.count { let k = q[j]; j += 1; let x = k % W, y = k / W
      for dy in -1...1 { for dx in -1...1 { let xx = x + dx, yy = y + dy
        if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
        if lab[n] < 0 && a[n] > 0.05 { lab[n] = id; q.append(n) } } } }
    areas.append(q.count)
  }
  let big = Double(areas.max() ?? 0)
  for k in 0..<P { if lab[k] < 0 || Double(areas[Int(lab[k])]) < big * 0.03 { a[k] = 0 } }
  let f = frames[t], pl = plates[t]
  var o = [Float](repeating: 0, count: P * 4)
  for k in 0..<P {
    let al = a[k]; o[k * 4 + 3] = al
    for c in 0..<3 {
      let C = Float(f.px[k * 4 + c]) / 255, B = Float(pl[k * 3 + c]) / 255
      let F = al > 0 ? min(1, max(0, B + (C - B) / max(al, 0.15))) : 0
      o[k * 4 + c] = F * al
    }
  }
  rgba.append(o)
}

// ───────── loop ─────────
func diff(_ a: [Float], _ b: [Float]) -> Double { var s = 0.0; for k in stride(from: 0, to: a.count, by: 4) { s += Double(abs(a[k] - b[k]) + abs(a[k + 1] - b[k + 1]) + abs(a[k + 2] - b[k + 2]) + abs(a[k + 3] - b[k + 3])) }; return s / Double(a.count) }
var consec: [Double] = []; for i in 1..<max(2, N) where N > 1 { consec.append(diff(rgba[i - 1], rgba[i])) }
let meanConsec = consec.isEmpty ? 0 : consec.reduce(0, +) / Double(consec.count)
let seamBefore = N > 1 ? diff(rgba[N - 1], rgba[0]) : 0
var outF = rgba
let K = min(xfade, N / 3)
if pingpong && N > 3 { outF = rgba + rgba[1..<(N - 1)].reversed() }
else if K > 0 && N > 3 {
  outF = (0..<(N - K)).map { j in
    if j >= K { return rgba[j] }
    let tt = Float(j + 1) / Float(K + 1), A = rgba[N - K + j], B = rgba[j]
    return (0..<A.count).map { A[$0] * (1 - tt) + B[$0] * tt }
  }
}
let NO = outF.count, seamAfter = NO > 1 ? diff(outF[NO - 1], outF[0]) : 0
// flicker index: mean |Δalpha| between consecutive output frames (loop included)
var flick = 0.0
if NO > 1 { for i in 0..<NO { let A = outF[i], B = outF[(i + 1) % NO]; var s = 0.0; for k in stride(from: 3, to: A.count, by: 4) { s += Double(abs(A[k] - B[k])) }; flick += s / Double(P) }; flick /= Double(NO) }

// ───────── crop, scale, write ─────────
var x0 = W, y0 = H, x1 = 0, y1 = 0
for o in outF { for y in 0..<H { for x in 0..<W where o[(y * W + x) * 4 + 3] > 0.03 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } } }
let pad = Int(Double(max(x1 - x0, y1 - y0)) * 0.04)
x0 = max(0, x0 - pad); y0 = max(0, y0 - pad); x1 = min(W - 1, x1 + pad); y1 = min(H - 1, y1 + pad)
let cw = x1 - x0 + 1, ch = y1 - y0 + 1
let th = (min(outH, Int(Double(ch) / scale)) / 2) * 2, tw = (Int(Double(cw) * Double(th) / Double(ch)) / 2) * 2
for (j, o) in outF.enumerated() {
  var px = [UInt8](repeating: 0, count: cw * ch * 4)
  for y in 0..<ch { for x in 0..<cw {
    let k = ((y + y0) * W + (x + x0)) * 4, q = (y * cw + x) * 4, al = o[k + 3]
    px[q + 3] = UInt8(min(255, max(0, al * 255 + 0.5)))
    for c in 0..<3 { px[q + c] = UInt8(min(255, max(0, (al > 0 ? o[k + c] / al : 0) * 255 + 0.5))) }
  } }
  let prov = CGDataProvider(data: Data(bytes: &px, count: px.count) as CFData)!
  let cg = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cw * 4, space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  let ci = CIImage(cgImage: cg).premultiplyingAlpha()
  let sx = Double(tw) / Double(cw), sy = Double(th) / Double(ch)
  let s = ci.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": sy, "inputAspectRatio": sx / sy]).unpremultiplyingAlpha()
  let outCG = ciCtx.createCGImage(s, from: CGRect(x: 0, y: 0, width: tw, height: th), format: .RGBA8, colorSpace: sRGB)!
  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/f_\(String(format: "%04d", j)).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, outCG, nil); CGImageDestinationFinalize(d)
}
let rep: [String: Any] = ["frames_in": N, "frames_out": NO, "xfade": pingpong ? 0 : K, "pingpong": pingpong, "out": [tw, th],
  "mean_consecutive_diff": meanConsec, "seam_diff_before": seamBefore, "seam_diff_after": seamAfter, "alpha_flicker": flick]
let js = try! JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys])
try! js.write(to: URL(fileURLWithPath: "\(outDir)/report.json"))
print(String(data: js, encoding: .utf8)!)
