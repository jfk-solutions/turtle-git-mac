#!/usr/bin/env python3
"""Summarize original Windows RedEye observations without inventing a classifier.

Direct ApplyEffect is compared with the observed GetPixel source atlas. Picture
replays are retained separately: source association may itself alter RGB bytes.
No port renderer is imported or used as an oracle.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path


def read_pixels(root, record):
    width, height = record["width"], record["height"]
    if not isinstance(width, int) or not isinstance(height, int) or not (0 < width <= 1024 and 0 < height <= 1024):
        raise ValueError("invalid observed dimensions")
    path = root / record["rgba"]
    if path.parent.resolve() != root.resolve():
        raise ValueError("observation path escapes artifact")
    data = path.read_bytes()
    if len(data) != width * height * 4:
        raise ValueError(f"invalid RGBA extent: {path.name}")
    return data, width, height, hashlib.sha256(data).hexdigest()


def analyze(root):
    manifest_path = root / "generate.json"
    document = json.loads(manifest_path.read_text())
    sources = {item["name"]: item for item in document["atlases"]}
    cases = []
    opaque_direction = Counter()
    observed_mapping = defaultdict(set)
    for item in document["cases"]:
        if item["family"] != "redEyeCorrection":
            continue
        record = {"name": item["name"], "parameters": item["parameters"]}
        direct = item.get("direct", {})
        record["recordSetParametersStatus"] = item.get("recordSetParametersStatus")
        record["setParametersStatus"] = direct.get("setParametersStatus")
        record["applyStatus"] = direct.get("applyStatus")
        if item.get("error") or direct.get("error"):
            record["error"] = item.get("error", direct.get("error"))
        if direct.get("setParametersStatus") != 0 or direct.get("applyStatus") != 0:
            cases.append(record)
            continue
        source, sw, sh, source_hash = read_pixels(root, sources[item["atlas"]])
        output, width, height, output_hash = read_pixels(root, direct)
        record.update(sourceSHA256=source_hash, outputSHA256=output_hash,
                      sourceSize=[sw, sh], outputSize=[width, height])
        if (sw, sh) != (width, height):
            record["extentChanged"] = True
            cases.append(record)
            continue
        changes = []
        outside = []
        alpha = []
        channel_changes = Counter()
        areas = item["parameters"]["areas"]
        for index in range(width * height):
            x, y = index % width, index // width
            before = tuple(source[index*4:index*4+4])
            after = tuple(output[index*4:index*4+4])
            observed_mapping[before].add(after)
            if before == after:
                continue
            changes.append([x, y, list(before), list(after)])
            if before[3] == 255 and after[3] == 255:
                opaque_direction[after[1]-before[1]-(after[2]-before[2])] += 1
            if not any(left <= x < right and top <= y < bottom
                       for left, top, right, bottom in areas):
                outside.append([x, y])
            if before[3] != after[3]:
                alpha.append([x, y, before[3], after[3]])
            for channel in range(4):
                if before[channel] != after[channel]:
                    channel_changes["RGBA"[channel]] += 1
        record.update(changedPixelCount=len(changes), opaqueChangedPixelCount=sum(v[2][3]==255 and v[3][3]==255 for v in changes), channelChanges=dict(channel_changes),
                      outsideRequestedAreas=outside, alphaChanges=alpha,
                      changedPixels=changes)
        cases.append(record)
    ambiguous = [{"input": list(color), "outputs": [list(v) for v in sorted(values)]}
                 for color, values in sorted(observed_mapping.items()) if len(values) > 1]
    return {
        "sourceManifest": str(manifest_path),
        "sourceManifestSHA256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "contract": "Original Windows direct ApplyEffect observations; no inferred formula or pixel parity claim",
        "caseCount": len(cases),
        "activeCaseCount": sum(item.get("changedPixelCount", 0) > 0 for item in cases),
        "opaqueGreenDeltaMinusBlueDeltaHistogram": dict(sorted(opaque_direction.items())),
        "outsideRequestedAreaChangeCount": sum(len(c.get("outsideRequestedAreas", [])) for c in cases),
        "alphaChangeCount": sum(len(c.get("alphaChanges", [])) for c in cases),
        "identicalInputWithDifferentOutput": ambiguous,
        "qualification": "Different outputs for equal input can reflect ROI membership, overlapping areas, context, or alpha. These causes are not distinguished by this report.",
        "cases": cases,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = analyze(args.artifact.resolve())
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"cases": report["caseCount"], "activeCases": report["activeCaseCount"], "report": str(args.output)}))


if __name__ == "__main__":
    main()
