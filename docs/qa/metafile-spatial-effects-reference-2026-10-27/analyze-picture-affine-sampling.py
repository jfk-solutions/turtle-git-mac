#!/usr/bin/env python3
"""Pure arithmetic source-derived Picture sampling discriminators.

All input planes are original retained Windows observations. This generates no
oracle and runs neither the app nor native/Core checks. Coordinates are generic
rectangle reciprocals/float32 row recurrences, never fitted fixture offsets.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
import numpy as np


def sha(data):
    return hashlib.sha256(data).hexdigest()


def down(value):
    rounded = np.float32(value)
    return float(np.nextafter(rounded, np.float32(-np.inf))) if float(rounded) > value else float(rounded)


def positions(count, step, half):
    value = down(half*step)
    result = []
    for _ in range(count):
        result.append(value-half)
        value = down(value+step)
    return np.array(result)


def associated(image):
    result = image.astype(float).copy()
    result[..., :3] = np.floor(result[..., :3]*result[..., 3, None]/255+.5)
    return result


def associate_straight(rgb, alpha):
    reciprocal = np.floor((255*65536)/np.where(alpha > 0, alpha, 1))
    return np.where(alpha > 0, np.minimum(255, np.floor(np.floor((rgb*alpha+127)/255)*reciprocal/65536)), 0)


def post_association(premultiplied, count):
    result = premultiplied.copy()
    if count:
        alpha = result[..., 3, None].astype(float)
        reciprocal = np.floor((255*65536)/np.where(alpha > 0, alpha, 1))
        rgb = np.where(alpha > 0, np.minimum(255, np.floor(result[..., :3]*reciprocal/65536)), 0)
        for _ in range(count):
            rgb = associate_straight(rgb, alpha)
        result[..., :3] = np.floor(rgb*alpha/255+.5).astype(int)
    return result


def sample(image, xs, ys):
    height, width, _ = image.shape
    source = associated(image)
    xs = np.floor(xs)+np.floor((xs-np.floor(xs))*2048+.5)/2048
    ys = np.floor(ys)+np.floor((ys-np.floor(ys))*2048+.5)/2048
    ix, iy = np.floor(xs).astype(int), np.floor(ys).astype(int)
    fx, fy = xs-ix, ys-iy
    def mirror(index, size):
        index = index % (2*size)
        return np.where(index < size, index, 2*size-1-index)
    x0, x1 = mirror(ix, width), mirror(ix+1, width)
    y0, y1 = mirror(iy, height), mirror(iy+1, height)
    result = np.zeros((len(ys), len(xs), 4), float)
    for xx, wx in [(x0, 1-fx), (x1, fx)]:
        for yy, wy in [(y0, 1-fy), (y1, fy)]:
            result += source[yy[:, None], xx[None, :]]*(wy[:, None]*wx[None, :])[..., None]
    return np.clip(np.floor(result+.5), 0, 255).astype(int)


def differences(actual, expected):
    delta = np.max(abs(actual-expected), axis=2)
    return dict(pixelsExceedingOne=int((delta > 1).sum()), maxByteDelta=int(delta.max()), nonexactPixels=int((delta > 0).sum()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--corpus', type=Path, required=True)
    parser.add_argument('--spatial-capture', type=Path, required=True)
    parser.add_argument('--roi-capture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((args.corpus/'windows-reference.json').read_text())
    cases = {case['file']: case for case in manifest['cases']}
    strips = [case for case in manifest['cases'] if case['file'].startswith('blur-strip-') and case['parameters']['radius'] in [1, 1.5, 3, 10]]
    recipes = ['identity', 'quotient-down', 'reciprocal-product-nearest', 'reciprocal-product-down', 'physical-div100-first', 'physical-density-first', 'physical-divmm-first']
    rows = []
    for case in strips:
        name, width, height = case['file'], case['width'], case['height']
        stem = Path(name).stem
        wire = (args.corpus/name).read_bytes()
        assert sha(wire) == case['sourceSHA256']
        intrinsic = (args.spatial_capture/f'replay-v1-{stem}-intrinsic.rgba').read_bytes()
        final = (args.spatial_capture/f'replay-v1-{stem}.rgba').read_bytes()
        assert sha(final) == case['rgbaSHA256']
        image = np.frombuffer(intrinsic, np.uint8).reshape(height, width, 4)
        expected = associated(np.frombuffer(final, np.uint8).reshape(height, width, 4))
        frame = struct.unpack_from('<4i', wire, 24)
        device, mm = struct.unpack_from('<2i', wire, 72), struct.unpack_from('<2i', wire, 80)
        physical = [frame[2]-frame[0], frame[3]-frame[1]]
        for recipe in recipes:
            steps = []
            for axis, size in enumerate([width, height]):
                if recipe == 'identity':
                    step = 1.
                elif recipe == 'quotient-down':
                    step = down(size/size)
                elif recipe == 'reciprocal-product-nearest':
                    step = float(np.float32(size*np.float32(1/size)))
                elif recipe == 'reciprocal-product-down':
                    step = down(size*down(1/size))
                else:
                    if recipe == 'physical-div100-first':
                        extent = down(down(physical[axis]/100)*down(device[axis]/mm[axis]))
                    elif recipe == 'physical-density-first':
                        extent = down(down(physical[axis]*down(device[axis]/mm[axis]))/100)
                    else:
                        extent = down(down(down(physical[axis]/mm[axis])*device[axis])/100)
                    step = down(down(extent+1)/size)
                steps.append(step)
            for half in [0, .5]:
                xs, ys = positions(width, steps[0], half), positions(height, steps[1], half)
                predicted = post_association(sample(image, xs, ys), 1)
                rows.append(dict(file=name, recipe=recipe, half=half, steps=steps, intrinsicSHA256=sha(intrinsic), finalSHA256=sha(final), lastIndexDifference=[float(xs[-1]-width+1), float(ys[-1]-height+1)], **differences(predicted, expected)))
    # The native SDK ROI is an independent source-plane observation for the
    # exact same original asymmetric pixels used by the scaled EMF draw.
    atlas = (args.spatial_capture/'atlas-asymmetric.rgba').read_bytes()
    assert atlas == (args.roi_capture/'atlas-roi-integer-e1.rgba').read_bytes()
    assert atlas == (args.roi_capture/'atlas-roi-integer-e1-requested.rgba').read_bytes()
    created = (args.roi_capture/'created-roi-integer-e1.rgba').read_bytes()
    image = np.frombuffer(created, np.uint8).reshape(20, 18, 4)
    final = (args.spatial_capture/'replay-v1-blur-asymmetric-crop-scale.rgba').read_bytes()
    assert sha(final) == cases['blur-asymmetric-crop-scale.emf']['rgbaSHA256']
    expected = associated(np.frombuffer(final, np.uint8).reshape(96, 96, 4))
    scaled = []
    for before in [0, 1, 2]:
        source = image.copy()
        for _ in range(before):
            source[..., :3] = associate_straight(source[..., :3].astype(float), source[..., 3, None].astype(float)).astype(np.uint8)
        for after in [0, 1, 2]:
            for half in [0, .5]:
                xs = positions(34, down(17*down(1/34)), half)
                ys = positions(29, down(19*down(1/28.5)), half)
                result = np.zeros((96, 96, 4), int)
                result[25:54, 24:58] = post_association(sample(source, xs, ys), after)
                scaled.append(dict(inputAssociations=before, outputAssociations=after, half=half, **differences(result, expected)))
    report = dict(qualification='Pure arithmetic development comparison against retained native observations; no new capture, oracle edit, fitted coordinate, app/helper/Core/native check.', sourceManifestSHA256=sha((args.corpus/'windows-reference.json').read_bytes()), sourceAtlasSHA256=sha(atlas), createdROI_SHA256=sha(created), stripCases=len(strips), stripPredictions=rows, scaledCropPredictions=scaled, research='Directed float32 row recurrence and nearest eleven-bit bilinear phase investigated from ChristopherVR/emf-converter effcf337218fefc08e4ac8f74e59cd2af1a9235c mathematical behavior; no external code incorporated.')
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    accepted = [row for row in rows if row['recipe'] == 'reciprocal-product-down' and row['half'] == .5]
    print(json.dumps(dict(stripCases=len(accepted), stripPixelsExceedingOne=sum(row['pixelsExceedingOne'] for row in accepted), scaledExact=next(row for row in scaled if row['inputAssociations'] == 0 and row['outputAssociations'] == 1 and row['half'] == 0))))


if __name__ == '__main__':
    main()
