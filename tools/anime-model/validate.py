"""Checks the converted network against the reference CartoonGAN code and renders before/after
images of a hand-frame photo, cropped and composited the way Postcam does it.

    env/bin/python validate.py --weights shinkai_makoto.pth --reference Transformer.py \
        --photo original.png --window 0.20,0.12,0.84,0.62 --out results
"""

import argparse
import importlib.util
import os
import time

import numpy as np
import torch
from PIL import Image

import math

from convert_cartoongan import SHAPES, load_generator, stylize_rgb


def reference_model(path, weights):
    spec = importlib.util.spec_from_file_location("reference", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    model = module.Transformer()
    model.load_state_dict(torch.load(weights, map_location="cpu"))
    return model.eval()


def fp16_weights(model):
    with torch.no_grad():
        for parameter in model.parameters():
            parameter.copy_(parameter.half().float())
    return model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--photo", required=True)
    parser.add_argument("--window", required=True, help="left,top,right,bottom as 0...1, top-down")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    ours = load_generator(args.weights)
    reference = reference_model(args.reference, args.weights)
    probe = torch.rand(1, 3, 128, 128) * 2 - 1
    with torch.no_grad():
        difference = (ours(probe) - reference(probe)).abs().max().item()
    print(f"max difference vs reference network: {difference:.5f}")

    photo = Image.open(args.photo).convert("RGB")
    width, height = photo.size
    left, top, right, bottom = (float(v) for v in args.window.split(","))
    box = (int(left * width), int(top * height), int(right * width), int(bottom * height))
    crop = photo.crop(box)

    for size in (256, 384, 512):
        sample = np.asarray(crop.resize((size, size), Image.BICUBIC))
        start = time.time()
        stylize_rgb(ours, sample)
        print(f"{size}x{size} on this VM's CPU (4 cores, PyTorch fp32): {time.time() - start:.2f} s")

    aspect = crop.size[0] / crop.size[1]
    shape = min(SHAPES, key=lambda wh: abs(math.log(aspect * wh[1] / wh[0])))
    print(f"window {crop.size[0]}x{crop.size[1]} -> model input {shape[0]}x{shape[1]}")
    sample = np.asarray(crop.resize(shape, Image.BICUBIC))
    styled = Image.fromarray(stylize_rgb(ours, sample))
    styled16 = Image.fromarray(stylize_rgb(fp16_weights(load_generator(args.weights)), sample))
    drift = np.abs(np.asarray(styled, dtype=np.int16) - np.asarray(styled16, dtype=np.int16))
    print(f"fp16 weights vs fp32: mean {drift.mean():.2f}, max {drift.max()} (0...255)")

    window = styled.resize(crop.size, Image.BICUBIC)
    composite = photo.copy()
    composite.paste(window, box[:2])

    full = np.asarray(photo.resize((512, int(512 * height / width)), Image.BICUBIC))
    full_styled = Image.fromarray(stylize_rgb(ours, full))

    crop.save(os.path.join(args.out, "window_before.png"))
    window.save(os.path.join(args.out, "window_after.png"))
    composite.save(os.path.join(args.out, "frame_after.png"))
    full_styled.save(os.path.join(args.out, "full_frame_stylized.png"))
    pair = Image.new("RGB", (width * 2, height))
    pair.paste(photo, (0, 0))
    pair.paste(composite, (width, 0))
    pair.resize((width, height // 2)).save(os.path.join(args.out, "before_after.png"))
    print("wrote", args.out)


if __name__ == "__main__":
    main()
