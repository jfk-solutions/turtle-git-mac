#!/usr/bin/env python3
"""Summarize original Windows observations; never manufacture expected pixels."""
import argparse
import json
from collections import defaultdict
from pathlib import Path


def read_cases(folder, name):
    value = json.loads((folder / name).read_text())
    return value["cases"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    folder = args.folder
    source = (folder / "atlas.rgba").read_bytes()
    assert len(source) == 32 * 32 * 4
    cases = read_cases(folder, "generate.json")
    families = defaultdict(list)
    failures = []
    for case in cases:
        if not case.get("rgba"):
            failures.append(case)
            continue
        observed = (folder / case["rgba"]).read_bytes()
        assert len(observed) == len(source), case["name"]
        # First 256 atlas positions are the complete opaque grayscale ramp.
        # Use its three independently observed channel mappings to test whether
        # arbitrary RGB samples really are separable, without assuming a model.
        for level in range(256):
            assert source[level * 4:level * 4 + 4] == bytes([level] * 3 + [255])
        deviations = 0
        maximum = 0
        for position in range(256, 985):
            for channel in range(3):
                mapped = observed[source[position * 4 + channel] * 4 + channel]
                delta = abs(observed[position * 4 + channel] - mapped)
                maximum = max(maximum, delta)
                deviations += delta != 0
        alpha_changes = sum(source[i] != observed[i] for i in range(3, len(source), 4))
        families[case["family"]].append({
            "name": case["name"], "parameters": case.get("parameters"),
            "gray_lut_rgb_max_delta": maximum,
            "gray_lut_rgb_differing_channels": deviations,
            "changed_alpha_samples": alpha_changes,
            "aux_bytes": case.get("auxBytes"),
        })
    replay = read_cases(folder, "replay.json")
    replay_one = {case.get("source", case["name"].removeprefix("replay-v1-")): case
                  for case in read_cases(folder, "replay-v1.json")}
    equal = 0
    unequal = []
    for case in replay:
        name = case.get("source", case["name"].removeprefix("replay-"))
        other = replay_one[name]
        if not case.get("rgba") or not other.get("rgba"):
            unequal.append({"name": name, "reason": "missing successful output"})
            continue
        a = (folder / case["rgba"]).read_bytes()
        b = (folder / other["rgba"]).read_bytes()
        if a == b:
            equal += 1
        else:
            assert len(a) == len(b)
            unequal.append({"name": name, "max_delta": max(abs(x-y) for x,y in zip(a,b)),
                            "differing_channels": sum(x != y for x,y in zip(a,b))})
    result = {"direct_case_count": len(cases), "direct_missing_output": failures,
              "families": dict(families), "replay_startup_identical_count": equal,
              "replay_startup_differences": unequal}
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
