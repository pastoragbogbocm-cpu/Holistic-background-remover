#!/usr/bin/env bash
# Builds the short person clips used by the on-device export test.
# The portrait is MediaPipe's own public test image; it is downloaded at test
# time and never committed.
set -euo pipefail
out="${1:?output dir}"
mkdir -p "$out"
img="$out/portrait.jpg"
curl -fsSL -o "$img" https://storage.googleapis.com/mediapipe-assets/portrait.jpg
common=(-loop 1 -framerate 30 -t 2 -i "$img"
        -f lavfi -t 2 -i "sine=frequency=440:sample_rate=48000")
enc=(-c:v libx264 -pix_fmt yuv420p -profile:v high -b:v 4M -c:a aac -b:a 128k -shortest -movflags +faststart)
# Upright portrait clip (like a gallery video with no rotation).
ffmpeg -y -loglevel error "${common[@]}" -vf "scale=720:900,setsar=1" "${enc[@]}" "$out/person.mp4"
# Phone-style clip: frame stored sideways (landscape) plus a 90 degree
# rotation tag, the way phone cameras record portrait video.
ffmpeg -y -loglevel error "${common[@]}" -vf "scale=720:900,setsar=1,transpose=2" "${enc[@]}" "$out/tmp_side.mp4"
ffmpeg -y -loglevel error -display_rotation -90 -i "$out/tmp_side.mp4" -c copy "$out/person_rot90.mp4"
rm -f "$out/tmp_side.mp4"
ls -la "$out"
