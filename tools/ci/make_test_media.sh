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
# Background music: an 880 Hz tone at 44.1 kHz (the clips' own sound is
# 440 Hz at 48 kHz), so tests can hear both and check resampling.
ffmpeg -y -loglevel error -f lavfi -t 5 -i "sine=frequency=880:sample_rate=44100" -ac 2 -c:a libmp3lame -b:a 160k "$out/music.mp3"
# Speech clip for captions: the person video with the JFK sample from
# whisper.cpp (public domain), 11 s.
jfk="$(dirname "$0")/../../third_party/whisper.cpp/samples/jfk.wav"
if [ -f "$jfk" ]; then
  ffmpeg -y -loglevel error -loop 1 -framerate 30 -t 11 -i "$img" -i "$jfk" \
    -vf "scale=720:900,setsar=1" -c:v libx264 -pix_fmt yuv420p -b:v 2M -c:a aac -b:a 128k -shortest "$out/speech.mp4"
fi
ls -la "$out"
