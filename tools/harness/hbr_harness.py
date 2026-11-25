#!/usr/bin/env python3
"""Desktop validation harness for the HBR pipeline.

Runs exactly the per-frame pipeline the phone apps run, on desktop:
  decode (8-bit 4:2:0, full resolution) -> person segmentation (MediaPipe
  selfie segmenter, the same .tflite the Android app bundles) -> hbr_core
  refine (temporal smoothing + guided-filter edges) -> hbr_core composite in
  Y'CbCr -> encode at source resolution / frame rate / bitrate, audio copied
  untouched.

Usage:
  python3 hbr_harness.py IN.mp4 OUT.mp4 --lib libhbr_core.so \
      --model selfie_segmenter.tflite [--bg color:#00b140 | image:PATH |
      blur:0.03 | video:PATH] [--landscape-model PATH] [--matte OUT_matte.mp4]
"""
import argparse
import ctypes as C
import json
import subprocess
import sys
import time

import numpy as np
from PIL import Image


class HbrConfig(C.Structure):
    _fields_ = [("width", C.c_int), ("height", C.c_int),
                ("temporal_strength", C.c_float), ("edge_radius", C.c_float),
                ("edge_eps", C.c_float), ("matte_low", C.c_float),
                ("matte_high", C.c_float), ("threads", C.c_int),
                ("decontaminate", C.c_int), ("edge_smoothing", C.c_float)]


class HbrYuv(C.Structure):
    _fields_ = [("y", C.c_void_p), ("y_stride", C.c_int), ("u", C.c_void_p),
                ("v", C.c_void_p), ("uv_stride", C.c_int),
                ("uv_pixel_stride", C.c_int)]


def nv12_view(buf, w, h):
    base = buf.ctypes.data
    return HbrYuv(base, w, base + w * h, base + w * h + 1, w, 2)


def probe(path):
    out = subprocess.check_output([
        "ffprobe", "-v", "error", "-print_format", "json", "-show_streams",
        "-show_format", path])
    info = json.loads(out)
    v = next(s for s in info["streams"] if s["codec_type"] == "video")
    a = next((s for s in info["streams"] if s["codec_type"] == "audio"), None)
    rot = 0
    for sd in v.get("side_data_list", []):
        if "rotation" in sd:
            rot = int(-int(sd["rotation"])) % 360  # ffprobe: counter-clockwise
    num, den = map(int, v["r_frame_rate"].split("/"))
    br = int(v.get("bit_rate") or 0) or int(info["format"].get("bit_rate") or 0)
    return dict(w=int(v["width"]), h=int(v["height"]), fps=f"{num}/{den}",
                fps_f=num / den, codec=v["codec_name"], bitrate=br, rot=rot,
                matrix=v.get("color_space", "bt709"),
                full_range=v.get("color_range") == "pc", audio=a is not None,
                nb_frames=int(v.get("nb_frames") or 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--lib", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--landscape-model")
    ap.add_argument("--bg", default="color:#00b140")
    ap.add_argument("--temporal", type=float, default=0.6)
    ap.add_argument("--edge-smoothing", type=float, default=None)
    ap.add_argument("--no-decontaminate", action="store_true")
    ap.add_argument("--matte", help="also write the alpha matte as a video")
    args = ap.parse_args()

    from ai_edge_litert.interpreter import Interpreter

    lib = C.CDLL(args.lib)
    lib.hbr_create.restype = C.c_void_p
    lib.hbr_alpha.restype = C.POINTER(C.c_uint8)
    for fn in ("hbr_destroy", "hbr_reset"):
        getattr(lib, fn).argtypes = [C.c_void_p]
    lib.hbr_refine_f32.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.c_void_p,
                                   C.c_int, C.c_int, C.c_int, C.c_int]
    lib.hbr_alpha.argtypes = [C.c_void_p, C.POINTER(C.c_int)]
    lib.hbr_composite_color.argtypes = [C.c_void_p, C.POINTER(HbrYuv),
                                        C.POINTER(HbrYuv), C.c_uint8,
                                        C.c_uint8, C.c_uint8]
    lib.hbr_composite_image.argtypes = [C.c_void_p, C.POINTER(HbrYuv),
                                        C.POINTER(HbrYuv), C.POINTER(HbrYuv)]
    lib.hbr_composite_blur.argtypes = [C.c_void_p, C.POINTER(HbrYuv),
                                       C.POINTER(HbrYuv), C.c_float]
    lib.hbr_yuv_to_rgba.argtypes = [C.POINTER(HbrYuv), C.c_int, C.c_int,
                                    C.c_void_p, C.c_int, C.c_int, C.c_int]
    lib.hbr_rgba_to_yuv_fill.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int,
                                         C.POINTER(HbrYuv), C.c_int, C.c_int,
                                         C.c_int, C.c_int]
    lib.hbr_scale_yuv_fill.argtypes = [C.POINTER(HbrYuv), C.c_int, C.c_int,
                                       C.POINTER(HbrYuv), C.c_int, C.c_int]
    lib.hbr_rgb_to_yuv.argtypes = [C.c_uint8] * 3 + [C.c_int, C.c_int] + \
        [C.POINTER(C.c_uint8)] * 3

    src = probe(args.input)
    W, H, rot = src["w"], src["h"], src["rot"]
    matrix = {"bt470bg": 0, "smpte170m": 0, "bt2020nc": 2}.get(src["matrix"], 1)
    full = 1 if src["full_range"] else 0
    disp_w, disp_h = (H, W) if rot in (90, 270) else (W, H)
    print(f"source: {W}x{H} rot={rot} {src['fps']}fps {src['codec']} "
          f"{src['bitrate'] / 1e6:.2f} Mbps audio={src['audio']}")

    model = args.model
    if args.landscape_model and disp_w > disp_h:
        model = args.landscape_model
    interp = Interpreter(model_path=model, num_threads=4)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    outd = interp.get_output_details()[0]
    mh_, mw_ = int(inp["shape"][1]), int(inp["shape"][2])

    cfg = HbrConfig()
    lib.hbr_default_config(C.byref(cfg), W, H)
    cfg.temporal_strength = args.temporal
    if args.edge_smoothing is not None:
        cfg.edge_smoothing = args.edge_smoothing
    if args.no_decontaminate:
        cfg.decontaminate = 0
    eng = C.c_void_p(lib.hbr_create(C.byref(cfg)))

    frame_bytes = W * H * 3 // 2
    out_buf = np.empty(frame_bytes, np.uint8)
    rgba = np.empty((H, W, 4), np.uint8)

    # ---- background setup
    kind, _, val = args.bg.partition(":")
    bg_buf = None
    bg_reader = None
    if kind == "color":
        r, g, b = (int(val.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
        yy, uu, vv = C.c_uint8(), C.c_uint8(), C.c_uint8()
        lib.hbr_rgb_to_yuv(r, g, b, matrix, full, C.byref(yy), C.byref(uu),
                           C.byref(vv))
        color = (yy.value, uu.value, vv.value)
    elif kind == "image":
        img = np.ascontiguousarray(np.asarray(Image.open(val).convert("RGBA")))
        # backgrounds are authored upright: rotate into storage orientation
        if rot:
            img = np.ascontiguousarray(np.rot90(img, k=rot // 90))
        bg_buf = np.empty(frame_bytes, np.uint8)
        lib.hbr_rgba_to_yuv_fill(img.ctypes.data, img.shape[1], img.shape[0],
                                 img.shape[1] * 4, C.byref(nv12_view(bg_buf, W, H)),
                                 W, H, matrix, full)
    elif kind == "video":
        bsrc = probe(val)
        bw, bh = bsrc["w"], bsrc["h"]
        bg_reader = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-stream_loop", "-1", "-i", val, "-f",
             "rawvideo", "-pix_fmt", "nv12", "-r", src["fps"], "-"],
            stdout=subprocess.PIPE)
        bg_raw = np.empty(bw * bh * 3 // 2, np.uint8)
        bg_buf = np.empty(frame_bytes, np.uint8)
    elif kind == "blur":
        blur_amount = float(val or 0.03)
    else:
        sys.exit(f"unknown background {args.bg}")

    dec = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-noautorotate", "-i", args.input, "-f",
         "rawvideo", "-pix_fmt", "nv12", "-"], stdout=subprocess.PIPE)

    # Source-quality encode: same size, same frame rate, same codec family,
    # bitrate >= source, colour tags preserved, audio stream-copied.
    vcodec = "libx265" if src["codec"] == "hevc" else "libx264"
    target_br = max(src["bitrate"], int(W * H * src["fps_f"] * 0.1))
    # Display rotation is carried over as metadata (pixels stay in storage
    # orientation, exactly like the source). ffmpeg wants counter-clockwise.
    rot_opts = ["-noautorotate", "-display_rotation:v",
                str((360 - rot) % 360)] if rot else []
    enc_cmd = ["ffmpeg", "-v", "error", "-y"] + rot_opts + ["-f", "rawvideo", "-pix_fmt",
               "nv12", "-s", f"{W}x{H}", "-framerate", src["fps"], "-i", "-",
               "-i", args.input, "-map", "0:v", "-map", "1:a?", "-c:a", "copy",
               "-c:v", vcodec, "-preset", "slow", "-b:v", str(target_br),
               "-maxrate", str(int(target_br * 1.5)), "-bufsize",
               str(target_br * 2), "-pix_fmt", "yuv420p",
               "-color_range", "pc" if full else "tv",
               "-colorspace", ["smpte170m", "bt709", "bt2020nc"][matrix]]
    enc_cmd.append(args.output)
    enc = subprocess.Popen(enc_cmd, stdin=subprocess.PIPE)
    matte_enc = None
    if args.matte:
        matte_enc = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt",
             "gray", "-s", f"{W}x{H}", "-framerate", src["fps"], "-i", "-",
             "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p",
             args.matte], stdin=subprocess.PIPE)

    t = dict(seg=0.0, refine=0.0, comp=0.0)
    n = 0
    while True:
        raw = dec.stdout.read(frame_bytes)
        if len(raw) < frame_bytes:
            break
        frame = np.frombuffer(raw, np.uint8).copy()
        sv = nv12_view(frame, W, H)

        t0 = time.perf_counter()
        lib.hbr_yuv_to_rgba(C.byref(sv), W, H, rgba.ctypes.data, W * 4,
                            matrix, full)
        small = Image.fromarray(rgba[:, :, :3])
        if rot:  # segment upright, like the phone apps do
            small = small.rotate(-rot, expand=True)
        small = small.resize((mw_, mh_), Image.BILINEAR)
        x = np.asarray(small, np.float32)[None] / 255.0
        interp.set_tensor(inp["index"], x)
        interp.invoke()
        mask = np.ascontiguousarray(interp.get_tensor(outd["index"])[0, :, :, 0])
        t1 = time.perf_counter()
        lib.hbr_refine_f32(eng, frame.ctypes.data, W, mask.ctypes.data, mw_,
                           mh_, mw_, rot)
        t2 = time.perf_counter()
        dv = nv12_view(out_buf, W, H)
        if kind == "color":
            lib.hbr_composite_color(eng, C.byref(sv), C.byref(dv), *color)
        elif kind == "blur":
            lib.hbr_composite_blur(eng, C.byref(sv),
                                   C.byref(dv), blur_amount)
        else:
            if bg_reader is not None:
                bg_raw[:] = np.frombuffer(bg_reader.stdout.read(bg_raw.size),
                                          np.uint8)
                lib.hbr_scale_yuv_fill(C.byref(nv12_view(bg_raw, bw, bh)), bw,
                                       bh, C.byref(nv12_view(bg_buf, W, H)), W,
                                       H)
            lib.hbr_composite_image(eng, C.byref(sv),
                                    C.byref(nv12_view(bg_buf, W, H)),
                                    C.byref(dv))
        t3 = time.perf_counter()
        t["seg"] += t1 - t0
        t["refine"] += t2 - t1
        t["comp"] += t3 - t2
        enc.stdin.write(out_buf.tobytes())
        if matte_enc:
            st = C.c_int()
            a = lib.hbr_alpha(eng, C.byref(st))
            matte_enc.stdin.write(C.string_at(a, W * H))
        n += 1
    enc.stdin.close()
    enc.wait()
    if matte_enc:
        matte_enc.stdin.close()
        matte_enc.wait()
    if bg_reader:
        bg_reader.kill()
    lib.hbr_destroy(eng)
    out = probe(args.output)
    ms = {k: 1000 * v / max(1, n) for k, v in t.items()}
    print(f"frames: {n}  per-frame ms: segmentation {ms['seg']:.1f}, "
          f"refine {ms['refine']:.1f}, composite {ms['comp']:.1f}")
    print(f"output: {out['w']}x{out['h']} rot={out['rot']} {out['fps']}fps "
          f"{out['codec']} {out['bitrate'] / 1e6:.2f} Mbps audio={out['audio']}")
    ok = (out["w"], out["h"], out["fps"], out["audio"], out["rot"]) == \
        (W, H, src["fps"], src["audio"], rot)
    print("source properties preserved:", "YES" if ok else "NO")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
