#!/usr/bin/env python3
"""Original procedural HSL model comparison against captured Windows SDK bytes.

This reads an existing artifact only. It does not build/run TurtleGit, launch a
reference process, or use captured parameter tables to produce model pixels.
"""
import argparse
import hashlib
import json
from pathlib import Path


def clip(value):
    return max(0, min(255, value))


def trunc_div(numerator, denominator):
    """C/Swift signed division, without Python's negative floor convention."""
    return numerator // denominator if numerator >= 0 else -((-numerator) // denominator)


def tables(hue, saturation, lightness):
    assert -180 <= hue <= 180 and -100 <= saturation <= 100 and -100 <= lightness <= 100
    # Half-up rounding is expressed as bounded rational integer arithmetic.
    # Hue endpoints are equivalent; 255 remains 255, rather than becoming zero.
    shift = ((hue if hue >= 0 else hue + 360) * 255 + 180) // 360
    hue_table = [x + shift - (255 if x + shift > 255 else 0) for x in range(256)]
    light_table = [clip((x * 100 + 255 * lightness + 50) // 100) for x in range(256)]
    saturation_table = [clip((x * (100 + saturation) + 50) // 100) for x in range(256)]
    return light_table, saturation_table, hue_table


def transform(rgb, prepared):
    red, green, blue = rgb
    high, low = max(rgb), min(rgb)
    delta = high - low
    total = high + low
    lightness = total // 2
    if delta == 0:
        hue = saturation = 0
    else:
        saturation = delta * 255 // (total if total <= 255 else 510 - total)
        # These asymmetric constants and tie priority are measured native
        # quantization, not an ideal floating HSL round trip. They explain why
        # neutral parameters still alter some opaque RGB values by >1 byte.
        if high == red:
            hue = trunc_div((green - blue) * 43, delta)
            if hue < 0:
                hue += 253
        elif high == blue:
            hue = (170 * delta + (red - green) * 43) // delta
        else:
            hue = (86 * delta + (blue - red) * 43) // delta
    light_table, saturation_table, hue_table = prepared
    lightness, saturation, hue = light_table[lightness], saturation_table[saturation], hue_table[hue]
    if saturation == 0:
        return (lightness,) * 3
    upper = (lightness * (255 + saturation) // 255 if lightness < 128
             else lightness + saturation - lightness * saturation // 255)
    lower = 2 * lightness - upper

    def component(position):
        if position < 0:
            position += 255
        if position > 255:
            position -= 255
        if position < 43:
            return lower + (upper - lower) * position // 43
        if position <= 128:
            return upper
        if position < 170:
            return lower + (upper - lower) * (170 - position) // 43
        return lower

    return component(hue + 85), component(hue), component(hue - 85)


def normalize(pixel):
    """Observed GDI+ straight->associated->straight fixed-reciprocal conversion."""
    *rgb, alpha = pixel
    if alpha == 0:
        return (0, 0, 0, 0)
    reciprocal = (255 << 16) // alpha
    return tuple(min(255, (((channel * alpha + 127) // 255) * reciprocal) >> 16)
                 for channel in rgb) + (alpha,)


def apply(pixel, prepared):
    return transform(pixel[:3], prepared) + (pixel[3],)


def compare(actual, expected):
    assert len(actual) == len(expected)
    differences = [abs(a - b) for a, b in zip(actual, expected)]
    return dict(channels=len(differences), mismatches=sum(x != 0 for x in differences),
                max_abs_delta=max(differences, default=0))


def combine(values):
    return dict(channels=sum(v["channels"] for v in values),
                mismatches=sum(v["mismatches"] for v in values),
                max_abs_delta=max((v["max_abs_delta"] for v in values), default=0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.artifact
    hashes = {}

    def read(name):
        assert Path(name).name == name, "artifact names must be local basenames"
        data = (root / name).read_bytes()
        hashes[name] = hashlib.sha256(data).hexdigest()
        return data

    atlas = read("atlas.rgba")
    assert len(atlas) == 32 * 32 * 4
    source = [tuple(atlas[i:i + 4]) for i in range(0, len(atlas), 4)]
    result = dict(model="original integer HSL quantization with rational parameter tables",
                  reference="native Windows SDK artifact; no production renderer involved",
                  qualification="Exact reported comparisons cover 33 captured parameter triples, not every valid parameter triple.",
                  normalization="N(c,a)=(((c*a+127)//255)*((255<<16)//a))>>16; N(rgb,0)=0",
                  modes={})
    for mode in ("generate", "direct-v1", "replay", "replay-v1"):
        manifest = json.loads(read(mode + ".json"))
        cases = [c for c in manifest["cases"] if c["family"] == "hueSaturationLightness"]
        assert len(cases) == 33
        rows = []
        for case in cases:
            parameters = case["parameters"]
            prepared = tables(parameters["hueLevel"], parameters["saturationLevel"], parameters["lightnessLevel"])
            observed = read(case["rgba"])
            assert len(observed) == len(atlas) and case["width"] == case["height"] == 32
            direct = mode in ("generate", "direct-v1")
            if direct:
                assert case["setParametersStatus"] == case["applyStatus"] == 0
                modeled = [apply(pixel, prepared) for pixel in source]
            else:
                assert case["bitmapLoadStatus"] == case["drawStatus"] == 0 and case["expectedSize"]
                assert case["intrinsicWidth"] == case["intrinsicHeight"] == 32
                modeled = [normalize(apply(normalize(pixel), prepared)) for pixel in source]
            row = dict(name=case["name"], parameters=parameters)
            # Opaque geometry/arithmetic is separate from 39 alpha/special cells.
            opaque = bytes(channel for pixel in modeled[:985] for channel in pixel[:3])
            opaque_expected = bytes(observed[i + c] for i in range(0, 985 * 4, 4) for c in range(3))
            row["opaque_rgb"] = compare(opaque, opaque_expected)
            if direct:
                all_pixels = bytes(channel for pixel in modeled for channel in pixel)
                row["all_rgba"] = compare(all_pixels, observed)
                lut = read(case["lut"])
                modeled_lut = bytes(prepared[0] + prepared[1] + prepared[2] + list(range(256)))
                row["aux_lut"] = compare(modeled_lut, lut)
            else:
                intrinsic = read(case["intrinsic"]["rgba"])
                row["intrinsic_rgba"] = compare(bytes(c for pixel in modeled for c in pixel), intrinsic)
                final = [normalize(pixel) for pixel in modeled]
                row["all_rgba"] = compare(bytes(c for pixel in final for c in pixel), observed)
            rows.append(row)
        keys = ("opaque_rgb", "all_rgba", "aux_lut") if direct else ("opaque_rgb", "intrinsic_rgba", "all_rgba")
        result["modes"][mode] = dict(summary={key:combine([row[key] for row in rows]) for key in keys}, cases=rows)
    result["inputSHA256"] = hashes
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
