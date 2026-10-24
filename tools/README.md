# Asset tools

How the animated Aaradhya clips and backgrounds in `assets/` were made from `~/Desktop/Meditation_Assets`.
The originals are only read. Open `tools/asset-preview.html` through the local server
(`http://localhost:4440/tools/asset-preview.html`) to see every result on different backdrops.

## Background removal + loop — `matte3.swift` (current)

Hybrid method, built after v2 showed blocky edge flicker and patches on bodies:
Vision's neural mask stabilised by a motion-adaptive temporal filter → halos removed only when they
connect to the real background → enclosed background pockets removed → a solid core (nothing inside
the body can turn transparent) → colour key against a per-frame clean plate, only on the uncertain rim →
holes refilled only where Vision called it figure → guided filter so edges follow the picture softly →
final motion-adaptive temporal smoothing, speck removal, edge colour decontamination.

```bash
swiftc -O tools/matte3.swift -o /tmp/matte3
A=~/Desktop/Meditation_Assets/Animated
/tmp/matte3 $A/Hanuman_Idle.mp4         out/hanuman-idle     --scale 0.5 --height 720 --start 19 --end 185 --xfade 10
/tmp/matte3 $A/Hanuman_Meditatin.mp4    out/hanuman-meditate --scale 0.6 --height 720 --pingpong
/tmp/matte3 $A/Ram_Idle.mp4             out/ram-idle         --scale 0.5 --height 720 --xfade 6
/tmp/matte3 $A/Ram_meditating.mp4       out/ram-meditate     --scale 0.6 --height 720 --pingpong
/tmp/matte3 $A/NaradMuni_Idle.mp4       out/narad-idle       --scale 0.5 --height 720 --start 3 --end 52 --pingpong
/tmp/matte3 $A/NaradMuni_Meditating.mp4 out/narad-meditate   --scale 0.6 --height 720 --pingpong
/tmp/matte3 ~/Desktop/Meditation_Assets/MeditatingShiv.png out/shiv-meditate --scale 0.6 --height 720
```

## Older method — `matte.swift` (v2, kept for reference)

Vision's foreground mask (temporally smoothed) gives the rough shape. Edges are then keyed against a
per-frame background plate (the frame with the figure filled in by push–pull), smooth background-coloured
or glowing regions (enclosed background, halos) are removed, semi-transparent texture-less haze is faded,
detached specks are dropped, and edge colours are decontaminated. Finally the tail is cross-faded into
the head (`--xfade N`) or the clip is played forward-then-back (`--pingpong`).

```bash
swiftc -O tools/matte.swift -o /tmp/matte
A=~/Desktop/Meditation_Assets/Animated
/tmp/matte $A/Hanuman_Idle.mp4        out/hanuman-idle     --scale 0.5 --height 720 --start 19 --end 185 --xfade 10 --simple
/tmp/matte $A/Hanuman_Meditatin.mp4   out/hanuman-meditate --scale 0.6 --height 720 --pingpong --simple
/tmp/matte $A/Ram_Idle.mp4            out/ram-idle         --scale 0.5 --height 720 --xfade 6
/tmp/matte $A/Ram_meditating.mp4      out/ram-meditate     --scale 0.6 --height 720 --pingpong
/tmp/matte $A/NaradMuni_Idle.mp4      out/narad-idle       --scale 0.5 --height 720 --start 3 --end 52 --pingpong   # clouds drift in after ~frame 60
/tmp/matte $A/NaradMuni_Meditating.mp4 out/narad-meditate  --scale 0.6 --height 720 --pingpong
/tmp/matte ~/Desktop/Meditation_Assets/MeditatingShiv.png "out/shiv-meditate" --scale 0.6 --height 720 --simple
```

`--analyze` prints the best loop windows (start/end frames whose pictures match most closely).
`--simple` suits figures without bright skin highlights (Hanuman, Shiv); the default mode protects them.

## Encoding

```bash
# Chrome / Android / Firefox: VP9 with alpha
ffmpeg -framerate 24 -i out/X/f_%04d.png -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 32 -row-mt 1 -auto-alt-ref 0 assets/av-X.webm
# Safari / iOS: HEVC with alpha
ffmpeg -framerate 24 -i out/X/f_%04d.png -c:v hevc_videotoolbox -alpha_quality 0.8 -q:v 52 -pix_fmt bgra -tag:v hvc1 assets/av-X.mov
cwebp -q 80 -alpha_q 90 out/X/f_0000.png -o assets/av-X.webp      # poster / still
```

Backgrounds: scaled to 720×1280 and the last 36 (forest) / 48 (clouds) frames dissolved into the first
ones with ffmpeg `xfade`, H.264 CRF 27, no audio. `swift tools/alphacheck.swift assets/av-*.mov` checks
the HEVC files' transparency the way Safari decodes them.
