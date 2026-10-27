#!/usr/bin/env python3
"""Compare general Tint approximations with an existing native Windows artifact.

These are original models, not claims to have recovered Windows' exact internal
algorithm. No per-hue/amount sample lookup is used. This runs mathematical byte
comparisons only, never the app, renderer, or a new Windows reference job.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def clip(value):
    return max(0, min(255, value))


def trunc_div(a, b):
    return a // b if a >= 0 else -((-a) // b)


def hue_palette(hue, upper):
    # Positive phases round half-up. Negative phases truncate signed and wrap
    # as an 8-bit code, retaining the observed asymmetric negative-hue phase.
    position = ((hue * 255 + 180) // 360 if hue >= 0 else trunc_div(hue * 255, 360)) % 256

    def component(t):
        if t < 0:
            t += 255
        if t > 255:
            t -= 255
        if t < 43:
            return upper * t // 43
        if t <= 128:
            return upper
        if t < 170:
            return upper * (170 - t) // 43
        return 0

    return component(position + 85), component(position), component(position - 85)


def luma_max(rgb, hue, amount):
    """Small-constant approximation: luma-preserving blend to a MAX hue color.

    Integer source weights approximate Rec.709. The bounded half-MAX color level
    and hue phases are observations-based approximations; they are not an SDK
    specified Tint formula. In particular, neutral amount retains source RGB,
    whereas native neutral Tint itself sometimes changes a channel by one.
    """
    upper = max(0, 2 * (max(rgb) // 2) - 1)
    target = hue_palette(hue, upper)
    source_y = (54 * rgb[0] + 183 * rgb[1] + 19 * rgb[2]) / 256
    target_y = (54 * target[0] + 183 * target[1] + 19 * target[2]) / 256
    scale = amount / 100
    return tuple(clip(math.floor(original + scale * (colored - original + source_y - target_y) + 0.5))
                 for original, colored in zip(rgb, target))


def yuv_max(rgb, hue, amount):
    """Alternative integer-coefficient YUV approximation, retained for comparison."""
    red, green, blue = rgb
    y = (54 * red + 183 * green + 19 * blue) / 256
    u = (-29 * red - 99 * green + 128 * blue) / 256
    v = (128 * red - 116 * green - 12 * blue) / 256
    r, g, b = hue_palette(hue, 254)
    target_u = (-29 * r - 99 * g + 128 * b) / 256
    target_v = (128 * r - 116 * g - 12 * b) / 256
    scale = amount / 100
    maximum = max(rgb) / 256
    u = (1 - scale) * u + scale * target_u * maximum
    v = (1 - scale) * v + scale * target_v * maximum
    return tuple(clip(math.floor(x)) for x in (y + 402 * v / 256,
                 y - (48 * u + 120 * v) / 256, y + 472 * u / 256))


def normalize(pixel):
    *rgb, alpha = pixel
    if alpha == 0:
        return (0, 0, 0, 0)
    reciprocal = (255 << 16) // alpha
    return tuple(min(255, (((c * alpha + 127) // 255) * reciprocal) >> 16) for c in rgb) + (alpha,)


def associated(pixel):
    *rgb, alpha = pixel
    return tuple((c * alpha + 127) // 255 for c in rgb) + (alpha,)


def compare(actual, expected):
    assert len(actual) == len(expected)
    histogram = {}
    for a, b in zip(actual, expected):
        delta = abs(a - b)
        histogram[str(delta)] = histogram.get(str(delta), 0) + 1
    return dict(channels=len(actual), max_abs_delta=max(map(int, histogram), default=0),
                mismatches=len(actual) - histogram.get("0", 0),
                above_one=sum(n for d, n in histogram.items() if int(d) > 1), histogram=histogram)


def combine(items):
    histogram = {}
    for item in items:
        for delta, count in item["histogram"].items():
            histogram[delta] = histogram.get(delta, 0) + count
    return dict(channels=sum(histogram.values()), max_abs_delta=max(map(int, histogram), default=0),
                mismatches=sum(n for d, n in histogram.items() if d != "0"),
                above_one=sum(n for d, n in histogram.items() if int(d) > 1), histogram=histogram)


def flatten(pixels):
    return bytes(c for pixel in pixels for c in pixel)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    hashes = {}

    def read(name):
        assert Path(name).name == name
        data = (args.artifact / name).read_bytes()
        hashes[name] = hashlib.sha256(data).hexdigest()
        return data

    source_bytes = read("atlas.rgba")
    assert len(source_bytes) == 32 * 32 * 4
    source = [tuple(source_bytes[i:i + 4]) for i in range(0, len(source_bytes), 4)]
    manifests = {mode:json.loads(read(mode + ".json")) for mode in ("generate", "direct-v1", "replay", "replay-v1")}
    result = dict(qualification="Approximation only. Bounds are observations on the 35 captured parameter pairs, not all valid Tint parameters or an independent holdout.",
                  shipping_candidate="luma_max: temporary functional profile; sampled associated-channel precision limit 3, not universal Windows parity",
                  remaining_gap="Windows exact Tint quantization and intermediates remain unresolved.", models={})
    for name, transform in (("luma_max", luma_max), ("yuv_max", yuv_max)):
        modes = {}
        for mode, manifest in manifests.items():
            cases = [c for c in manifest["cases"] if c["family"] == "tint"]
            assert len(cases) == 35
            rows = []
            direct = mode in ("generate", "direct-v1")
            for case in cases:
                hue, amount = case["parameters"]["hue"], case["parameters"]["amount"]
                actual = read(case["rgba"])
                assert len(actual) == len(source_bytes) and case["width"] == case["height"] == 32
                if direct:
                    assert case["setParametersStatus"] == case["applyStatus"] == 0
                else:
                    assert case["bitmapLoadStatus"] == case["drawStatus"] == 0 and case["expectedSize"]
                    assert case["intrinsicWidth"] == case["intrinsicHeight"] == 32
                modeled = []
                for original in source:
                    pixel = original if direct else normalize(original)
                    changed = transform(pixel[:3], hue, amount) + (pixel[3],)
                    modeled.append(changed if direct else normalize(changed))
                row = dict(name=case["name"], parameters=case["parameters"])
                if not direct:
                    intrinsic = read(case["intrinsic"]["rgba"])
                    row["intrinsic_straight_rgba"] = compare(flatten(modeled), intrinsic)
                    row["intrinsic_associated_rgba"] = compare(flatten([associated(p) for p in modeled]),
                        flatten([associated(intrinsic[i:i + 4]) for i in range(0, len(intrinsic), 4)]))
                    modeled = [normalize(pixel) for pixel in modeled]
                row["final_straight_rgba"] = compare(flatten(modeled), actual)
                row["final_associated_rgba"] = compare(flatten([associated(p) for p in modeled]),
                    flatten([associated(actual[i:i + 4]) for i in range(0, len(actual), 4)]))
                opaque = bytes(c for pixel in modeled[:985] for c in pixel[:3])
                opaque_expected = bytes(actual[i + c] for i in range(0, 985 * 4, 4) for c in range(3))
                row["opaque_rgb"] = compare(opaque, opaque_expected)
                rows.append(row)
            keys = [k for k in rows[0] if k not in ("name", "parameters")]
            modes[mode] = dict(summary={key:combine([row[key] for row in rows]) for key in keys},
                               above_one_cases=[row["name"] for row in rows if row["final_associated_rgba"]["above_one"]],
                               cases=rows)
        result["models"][name] = modes
    result["inputSHA256"] = hashes
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
