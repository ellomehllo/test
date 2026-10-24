// alphacheck.swift — decodes every frame of an HEVC-with-alpha .mov with AVFoundation (as Safari/iOS do)
// and reports whether the frame border is transparent and the figure opaque.
// usage: swift tools/alphacheck.swift assets/av-*.mov
import AVFoundation

for path in CommandLine.arguments.dropFirst() {
  let asset = AVURLAsset(url: URL(fileURLWithPath: path))
  let sem = DispatchSemaphore(value: 0); var track: AVAssetTrack?
  Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }; sem.wait()
  guard let tr = track, let reader = try? AVAssetReader(asset: asset) else { print("\(path): unreadable"); continue }
  let out = AVAssetReaderTrackOutput(track: tr, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(out); reader.startReading()
  var frames = 0, edgeFrames = 0, minCenter = 255, maxCorner = 0
  while let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let a = { (x: Int, y: Int) in Int(p[y * row + x * 4 + 3]) }
    let corner = max(a(1, 1), a(w - 2, 1), a(1, h / 2), a(w - 2, h / 2))
    maxCorner = max(maxCorner, corner); minCenter = min(minCenter, a(w / 2, h * 6 / 10))
    if corner > 16 { edgeFrames += 1 }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly); frames += 1
  }
  print("\((path as NSString).lastPathComponent): frames=\(frames) side-edge alpha max=\(maxCorner) (frames>16: \(edgeFrames)) centre alpha min=\(minCenter)")
}
