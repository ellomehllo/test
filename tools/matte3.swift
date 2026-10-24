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
let glowLo = Float(opt("--glow", 226)), choke = Float(opt("--choke", 0))   // --choke 0.4: tighter, crisper rim (removes painted glow halos)
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
let N = frames.count
var P = W * H
log("frames \(N) at \(W)x\(H)")
var luma: [[Float]] = frames.map { f in (0..<P).map { k in 0.299 * Float(f.px[k * 4]) + 0.587 * Float(f.px[k * 4 + 1]) + 0.114 * Float(f.px[k * 4 + 2]) } }

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
    var s = [Float](repeating: 0, count: P), ws = [Float](repeating: 0, count: P)
    let b = frames[t].px
    for j in -radius...radius {
      let u = t + j; if u < 0 || u >= maps.count { continue }
      // full colour difference, not just brightness: a tan tail over a cream glow is a big change
      let a = frames[u].px, mu = maps[u], g = gw[abs(j)], inv = 1 / sigma
      for k in 0..<P {
        let q = k * 4
        let dr = Float(a[q]) - Float(b[q]), dg = Float(a[q + 1]) - Float(b[q + 1]), db = Float(a[q + 2]) - Float(b[q + 2])
        let dc = (0.3 * dr * dr + 0.59 * dg * dg + 0.11 * db * db + 0.5 * (dr - db) * (dr - db)).squareRoot() * inv
        let w = g * exp(-dc * dc)
        s[k] += mu[k] * w; ws[k] += w
      }
    }
    for k in 0..<P { s[k] /= ws[k] }
    out[t] = s
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
// crop to the figure early (union of all masks + margin): far less memory and time at full resolution
do {
  var bx0 = W, by0 = H, bx1 = 0, by1 = 0
  for m in masks { for y in 0..<H { for x in 0..<W where m[y * W + x] > 0.05 { bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y) } } }
  let mg = Int(Double(max(bx1 - bx0, by1 - by0)) * 0.08)
  bx0 = max(0, bx0 - mg); by0 = max(0, by0 - mg); bx1 = min(W - 1, bx1 + mg); by1 = min(H - 1, by1 + mg)
  let nw = bx1 - bx0 + 1, nh = by1 - by0 + 1, ow = W
  func cropF(_ a: [Float]) -> [Float] { var o = [Float](repeating: 0, count: nw * nh); for y in 0..<nh { for x in 0..<nw { o[y * nw + x] = a[(y + by0) * ow + x + bx0] } }; return o }
  frames = frames.map { f in var o = [UInt8](repeating: 0, count: nw * nh * 4)
    for y in 0..<nh { let src = ((y + by0) * ow + bx0) * 4; o.replaceSubrange((y * nw * 4)..<((y + 1) * nw * 4), with: f.px[src..<(src + nw * 4)]) }
    return Frame(px: o) }
  luma = luma.map(cropF); masks = masks.map(cropF)
  W = nw; H = nh; P = W * H
  log("cropped to \(W)x\(H)")
}
masks = temporal(masks, radius: 3, sigma: 12)
log("masks done")

// ───────── 2. background decisions, made per frame (pass 1) ─────────
// Halo/glow connected to the outside and enclosed background pockets are decided here for every frame,
// then voted across neighbouring frames so a region on a threshold can't flicker in and out.
let band = Float(opt("--band", 14) * scale / 0.5)
let r3 = max(3, Int(3 * scale / 0.5)), r6 = max(6, Int(6 * scale / 0.5))
var remRaw: [[Float]] = [], plates: [[UInt8]] = [], dists: [[UInt8]] = [], lstds: [[UInt8]] = []
for t in 0..<N {
  let f = frames[t], L = luma[t], m = masks[t]
  let lum01 = L.map { $0 / 255 }
  let mean = boxMean(lum01, r3), mean2 = boxMean(lum01.map { $0 * $0 }, r3)
  let lstd = (0..<P).map { k in max(0, mean2[k] - mean[k] * mean[k]).squareRoot() * 255 }
  // plate: the frame with the figure (mask + margin) inpainted away
  let outside = distanceTo(m.map { $0 > 0.25 }, borderIsSeed: false)
  var col = [Float](repeating: 0, count: P * 3), wt = [Float](repeating: 0, count: P)
  for k in 0..<P { for c in 0..<3 { col[k * 3 + c] = Float(f.px[k * 4 + c]) }; wt[k] = outside[k] > band * 1.4 ? 1 : 0 }
  let plate = pushPull(col, wt, W, H)
  var bgMean: (Float, Float, Float) = (0, 0, 0); var bn: Float = 0
  for k in stride(from: 0, to: P, by: 5) where wt[k] > 0 { bgMean.0 += plate[k * 3]; bgMean.1 += plate[k * 3 + 1]; bgMean.2 += plate[k * 3 + 2]; bn += 1 }
  if bn > 0 { bgMean = (bgMean.0 / bn, bgMean.1 / bn, bgMean.2 / bn) }
  var dist = [Float](repeating: 0, count: P)
  for k in 0..<P {
    let dr = Float(f.px[k * 4]) - plate[k * 3], dg = Float(f.px[k * 4 + 1]) - plate[k * 3 + 1], db = Float(f.px[k * 4 + 2]) - plate[k * 3 + 2]
    dist[k] = (0.3 * dr * dr + 0.59 * dg * dg + 0.11 * db * db).squareRoot() + abs(dr - db) * 0.3
  }
  // halo/glow: smooth + (bright warm, or background-coloured), connected to the outside → not figure
  var glowy = [Bool](repeating: false, count: P)
  for k in 0..<P where m[k] > 0.05 {
    let r = Float(f.px[k * 4]), g = Float(f.px[k * 4 + 1]), b = Float(f.px[k * 4 + 2])
    let smooth = lstd[k] < 5
    let dr = r - bgMean.0, dg = g - bgMean.1, db = b - bgMean.2
    let bgCol = (dr * dr + dg * dg + db * db).squareRoot() < 20
    let warmBright = L[k] > glowLo && r >= g - 4 && g >= b - 4 && dist[k] < 22   // glow is close to the plate; skin is warmer
    let sat = max(r, g, b) - min(r, g, b)
    let whiteGlow = L[k] > 226 && sat < 45 && lstd[k] < 14   // a halo at its brightest is near-white (its painted ring adds texture)
    glowy[k] = (smooth && (bgCol || warmBright)) || whiteGlow
  }
  var rem = [Float](repeating: 0, count: P)
  var reach = [Bool](repeating: false, count: P); var q: [Int] = []
  for k in 0..<P where m[k] <= 0.05 { reach[k] = true; q.append(k) }
  var qi = 0
  while qi < q.count { let k = q[qi]; qi += 1; let x = k % W, y = k / W
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { let xx = x + dx, yy = y + dy
      if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
      if !reach[n] && glowy[n] { reach[n] = true; q.append(n) } } }
  for k in 0..<P where reach[k] && m[k] > 0.05 { rem[k] = 1 }
  // enclosed background pockets (between arm and body, behind a bow), big enough not to be a highlight
  var pocket = [Bool](repeating: false, count: P)
  let wmean = boxMean(lum01, r6), wmean2 = boxMean(lum01.map { $0 * $0 }, r6)
  let wstd = (0..<P).map { k in max(0, wmean2[k] - wmean[k] * wmean[k]).squareRoot() * 255 }
  for k in 0..<P where m[k] > 0.05 && m[k] < 0.85 && lstd[k] < 4 {   // Vision-confident skin is never a pocket
    let r = Float(f.px[k * 4]), g = Float(f.px[k * 4 + 1]), b = Float(f.px[k * 4 + 2])
    let dr = r - bgMean.0, dg = g - bgMean.1, db = b - bgMean.2
    let sat = max(r, g, b) - min(r, g, b)
    let warmGlow = L[k] > 196 && r >= g && g >= b && sat < 80 && wstd[k] < 3.2 && lstd[k] < 1.6
    pocket[k] = (dr * dr + dg * dg + db * db).squareRoot() < 18 || (L[k] > 236 && sat < 32) || warmGlow
  }
  let minPocket = Int(Float(P) * 0.0004)
  var plab = [Int32](repeating: -1, count: P); var pid: Int32 = 0
  for k0 in 0..<P where pocket[k0] && plab[k0] < 0 {
    var qq = [k0]; plab[k0] = pid; var j = 0
    while j < qq.count { let k = qq[j]; j += 1; let x = k % W, y = k / W
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { let xx = x + dx, yy = y + dy
        if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
        if pocket[n] && plab[n] < 0 { plab[n] = pid; qq.append(n) } } }
    if qq.count >= minPocket { for k in qq { rem[k] = 1 } }
    pid += 1
  }
  if let pi = args.firstIndex(of: "--probe"), Int(args[pi + 3]) == t {   // debug: what the decisions see around (x,y)
    let px0 = Int(args[pi + 1])!, py0 = Int(args[pi + 2])!
    for dy in stride(from: -30, through: 30, by: 15) { var line = ""
      for dx in stride(from: -30, through: 30, by: 15) { let k = (py0 + dy) * W + px0 + dx
        let r = Int(f.px[k * 4]), g = Int(f.px[k * 4 + 1]), b = Int(f.px[k * 4 + 2])
        line += String(format: "[m%.2f d%3.0f L%3.0f %d,%d,%d s%.1f %@] ", m[k], dist[k], L[k], r, g, b, lstd[k], rem[k] > 0 ? (pocket[k] ? "P" : "G") : "-") }
      log(line) }
    log("bg \(bgMean)")
  }
  remRaw.append(rem)
  plates.append(plate.map { UInt8(min(255, max(0, $0))) })
  dists.append(dist.map { UInt8(min(255, max(0, $0))) })
  lstds.append(lstd.map { UInt8(min(255, max(0, $0 * 4))) })   // ×4 for precision at low values
  if t % 20 == 0 { log("pass 1 frame \(t)") }
}
// vote: a pixel's background decision follows its neighbours wherever the picture hasn't changed
let legacy = args.contains("--legacy")   // previous behaviour, for comparison
let remVoted = (legacy ? remRaw : temporal(remRaw, radius: 4, sigma: 12)).map { $0.map { $0 > 0.5 } }
remRaw = []

// ───────── 3–6. the matte from steadied decisions (pass 2) ─────────
var alphas: [[Float]] = []
for t in 0..<N {
  let f = frames[t], L = luma[t]
  let lum01 = L.map { $0 / 255 }
  var m = masks[t]
  let removedBg = remVoted[t]
  for k in 0..<P where removedBg[k] { m[k] = 0 }
  let dist = dists[t].map { Float($0) }
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
  // thin pale rings (a painted halo hugging the crown): thinner than ~8 px, light and desaturated → not figure
  let thinR = Float(4 * scale / 0.5)
  let nearCore = distanceTo(dIn.map { $0 >= thinR }, borderIsSeed: false)
  // white backlight fringe: bright, desaturated pixels near the silhouette fade out
  var ring = [Bool](repeating: false, count: P)
  for k in 0..<P where a[k] > 0 {
    let r = Float(f.px[k * 4]), g = Float(f.px[k * 4 + 1]), b = Float(f.px[k * 4 + 2])
    let sat = max(r, g, b) - min(r, g, b)
    if fig[k] && nearCore[k] > thinR + 1 && L[k] > 210 && sat < 50 { a[k] = 0; ring[k] = true; continue }
    let white = smoothstep(198, 234, L[k]) * (1 - smoothstep(35, 75, sat))
    let rim = 1 - smoothstep(band * 0.35, band, dIn[k])
    a[k] *= 1 - white * rim
    if choke > 0 {   // painted warm backlight right at the silhouette (never where Vision is sure it's figure, e.g. a tail fading into light)
      let outer = 1 - smoothstep(band * 0.1, band * 0.4, dIn[k])
      a[k] *= 1 - smoothstep(212, 238, L[k]) * outer * (1 - smoothstep(0.9, 0.99, masks[t][k]))
    }
  }
  // a ring painted across a limb (the halo over the tail): where a removed ring pixel has figure on both sides,
  // keep it and repaint it from the surrounding figure so the limb stays whole
  // a limb washed out by a painted glow (the tail behind the halo): bright, desaturated figure pixels that connect
  // to removed halo/ring pixels are repainted from the surrounding figure. A white tilak or garland is enclosed by
  // skin and flowers, so it can never connect.
  var washed = [Bool](repeating: false, count: P)
  do {
    var cand = [Bool](repeating: false, count: P)
    for k in 0..<P where a[k] > 0.3 && !ring[k] && !removedBg[k] {
      let r = Float(f.px[k * 4]), g = Float(f.px[k * 4 + 1]), b = Float(f.px[k * 4 + 2])
      cand[k] = L[k] > 220 && max(r, g, b) - min(r, g, b) < 65
    }
    var q: [Int] = []
    for k in 0..<P where cand[k] {
      let x = k % W, y = k / W
      outer: for dy in -2...2 { for dx in -2...2 { let xx = x + dx, yy = y + dy
        if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
        if ring[n] || removedBg[n] { washed[k] = true; q.append(k); break outer } } }
    }
    var qi = 0
    while qi < q.count { let k = q[qi]; qi += 1; let x = k % W, y = k / W
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { let xx = x + dx, yy = y + dy
        if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }; let n = yy * W + xx
        if cand[n] && !washed[n] { washed[n] = true; q.append(n) } } }
  }
  let solid = (0..<P).map { a[$0] > 0.4 && !ring[$0] && !washed[$0] }
  var bridge = [Bool](repeating: false, count: P), anyBridge = false
  let reachB = Int(7 * scale / 0.5)
  for k in 0..<P where ring[k] {
    let x = k % W, y = k / W
    for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
      var plus = false, minus = false
      for r in 1...reachB {
        let x1 = x + dx * r, y1 = y + dy * r, x2 = x - dx * r, y2 = y - dy * r
        if !plus, x1 >= 0, y1 >= 0, x1 < W, y1 < H, solid[y1 * W + x1] { plus = true }
        if !minus, x2 >= 0, y2 >= 0, x2 < W, y2 < H, solid[y2 * W + x2] { minus = true }
      }
      if plus && minus { bridge[k] = true; anyBridge = true; break }
    }
  }
  if washed.contains(true) { anyBridge = true }
  if anyBridge {
    var col = [Float](repeating: 0, count: P * 3), wt = [Float](repeating: 0, count: P)
    for k in 0..<P where solid[k] { for c in 0..<3 { col[k * 3 + c] = Float(f.px[k * 4 + c]) }; wt[k] = 1 }
    let fill = pushPull(col, wt, W, H)
    for k in 0..<P where bridge[k] || washed[k] {
      if bridge[k] { a[k] = 1 }
      for c in 0..<3 { frames[t].px[k * 4 + c] = UInt8(min(255, max(0, fill[k * 3 + c]))) }
    }
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
  if let di = args.firstIndex(of: "--dumpframe"), Int(args[di + 1]) == t {   // debug: intermediate maps of one frame
    func gray(_ v: [Float], _ name: String) {
      var px = [UInt8](repeating: 0, count: P * 4)
      for k in 0..<P { let g = UInt8(min(255, max(0, v[k] * 255))); px[k * 4] = g; px[k * 4 + 1] = g; px[k * 4 + 2] = g; px[k * 4 + 3] = 255 }
      let prov = CGDataProvider(data: Data(bytes: &px, count: px.count) as CFData)!
      let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
      let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(args[di + 2])/\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
    }
    gray(masks[t], "1-vision"); gray(removedBg.map { $0 ? 1 : 0 }, "2-removed"); gray(a, "3-alpha"); gray(L.map { $0 / 255 }, "0-luma")
  }
  alphas.append(a)
  if t % 20 == 0 { log("pass 2 frame \(t)") }
}

// ───────── 7. temporal smoothing, specks, decontamination ─────────
// wider than before: where the picture is steady the matte must be steady too; moving parts keep their own frames
alphas = legacy ? temporal(alphas, radius: 1, sigma: 8) : temporal(alphas, radius: 3, sigma: 11)
// diagnostic: "unjustified" flicker = matte changes where the picture itself didn't change
var unjust = 0.0, heat = [Float](repeating: 0, count: P)
if N > 1 { for t in 1..<N { for k in 0..<P {
  let dl = (luma[t][k] - luma[t - 1][k]) / 5, w = exp(-dl * dl), d = abs(alphas[t][k] - alphas[t - 1][k]) * w
  unjust += Double(d); heat[k] += d } }; unjust /= Double((N - 1) * P) }
log(String(format: "unjustified flicker %.6f", unjust))
if let di = args.firstIndex(of: "--diag"), di + 1 < args.count {   // heat map of unjustified flicker over the source frame
  let mx = max(1e-6, heat.max() ?? 1)
  var px = [UInt8](repeating: 0, count: P * 4)
  for k in 0..<P {
    let v = min(1, heat[k] / (mx * 0.25)), g = UInt8(min(255, max(0, luma[N / 2][k] * 0.35)))
    px[k * 4] = UInt8(min(255, Float(g) + v * 255)); px[k * 4 + 1] = UInt8(min(255, Float(g) + v * 60)); px[k * 4 + 2] = g; px[k * 4 + 3] = 255
  }
  let prov = CGDataProvider(data: Data(bytes: &px, count: px.count) as CFData)!
  let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[di + 1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}
var rgba: [[UInt8]] = []   // premultiplied RGBA8 (floats would need gigabytes at full resolution)
for t in 0..<N {
  var a = alphas[t]
  let lo = choke > 0 ? choke : 0.04
  for k in 0..<P { a[k] = smoothstep(lo, 0.96, a[k]) }                 // choke: no faint fringe ring
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
  var o = [UInt8](repeating: 0, count: P * 4)
  for k in 0..<P {
    let al = a[k]; o[k * 4 + 3] = UInt8(min(255, max(0, al * 255 + 0.5)))
    for c in 0..<3 {
      let C = Float(f.px[k * 4 + c]) / 255, B = Float(pl[k * 3 + c]) / 255
      let F = al > 0 ? min(1, max(0, B + (C - B) / max(al, 0.15))) : 0
      o[k * 4 + c] = UInt8(min(255, max(0, F * al * 255 + 0.5)))
    }
  }
  rgba.append(o)
  frames[t] = Frame(px: []); plates[t] = []
}

// ───────── loop ─────────
func diff(_ a: [UInt8], _ b: [UInt8]) -> Double { var s = 0; for k in 0..<a.count { s += abs(Int(a[k]) - Int(b[k])) }; return Double(s) / Double(a.count) / 255 }
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
    return (0..<A.count).map { UInt8(Float(A[$0]) * (1 - tt) + Float(B[$0]) * tt + 0.5) }
  }
}
let NO = outF.count, seamAfter = NO > 1 ? diff(outF[NO - 1], outF[0]) : 0
// flicker index: mean |Δalpha| between consecutive output frames (loop included)
var flick = 0.0
if NO > 1 { for i in 0..<NO { let A = outF[i], B = outF[(i + 1) % NO]; var s = 0; for k in stride(from: 3, to: A.count, by: 4) { s += abs(Int(A[k]) - Int(B[k])) }; flick += Double(s) / 255 / Double(P) }; flick /= Double(NO) }

// ───────── crop, scale, write ─────────
var x0 = W, y0 = H, x1 = 0, y1 = 0
for o in outF { for y in 0..<H { for x in 0..<W where o[(y * W + x) * 4 + 3] > 8 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } } }
let pad = Int(Double(max(x1 - x0, y1 - y0)) * 0.04)
x0 = max(0, x0 - pad); y0 = max(0, y0 - pad); x1 = min(W - 1, x1 + pad); y1 = min(H - 1, y1 + pad)
let cw = x1 - x0 + 1, ch = y1 - y0 + 1
let th = (min(outH, Int(Double(ch) / scale)) / 2) * 2, tw = (Int(Double(cw) * Double(th) / Double(ch)) / 2) * 2
for (j, o) in outF.enumerated() {
  var px = [UInt8](repeating: 0, count: cw * ch * 4)
  for y in 0..<ch { for x in 0..<cw {
    let k = ((y + y0) * W + (x + x0)) * 4, q = (y * cw + x) * 4, al = Int(o[k + 3])
    px[q + 3] = UInt8(al)
    for c in 0..<3 { px[q + c] = al > 0 ? UInt8(min(255, Int(o[k + c]) * 255 / al)) : 0 }
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
  "mean_consecutive_diff": meanConsec, "seam_diff_before": seamBefore, "seam_diff_after": seamAfter, "alpha_flicker": flick, "unjustified_flicker": unjust]
let js = try! JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys])
try! js.write(to: URL(fileURLWithPath: "\(outDir)/report.json"))
print(String(data: js, encoding: .utf8)!)
