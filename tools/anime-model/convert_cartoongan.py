"""Converts the CartoonGAN Makoto Shinkai generator to a Core ML package for Postcam.

CartoonGAN: Chen, Lai, Liu, "CartoonGAN: Generative Adversarial Networks for Photo
Cartoonization", CVPR 2018. Weights released by the authors, converted to PyTorch by Yijun Li
(github.com/Yijunmaverick/CartoonGAN-Test-Pytorch-Torch, MIT) and repackaged at
huggingface.co/akiyamasho/AnimeBackgroundGAN-Shinkai (MIT).

    python3 -m venv env && env/bin/pip install torch==2.4.0 coremltools==8.1 pillow numpy
    curl -L -o shinkai_makoto.pth \
        https://huggingface.co/akiyamasho/AnimeBackgroundGAN-Shinkai/resolve/main/shinkai_makoto.pth
    env/bin/python convert_cartoongan.py --weights shinkai_makoto.pth --out ../../Postcam/Models

The package takes a BGRA camera-style image (any 8-bit BGRA pixel buffer of the input size) and
returns the stylized image of the same size. Pre- and post-processing ([-1, 1] scaling, BGR
order, tanh back to 0...255) live inside the model so the app only moves pixel buffers.
"""

import argparse
import os

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


class Generator(nn.Module):
    """CartoonGAN generator with stock InstanceNorm2d, so Core ML gets its native instance_norm."""

    def __init__(self, eps=1e-5):
        super().__init__()

        def norm(channels):
            return nn.InstanceNorm2d(channels, affine=True, eps=eps)

        self.refpad01_1 = nn.ReflectionPad2d(3)
        self.conv01_1 = nn.Conv2d(3, 64, 7)
        self.in01_1 = norm(64)
        self.conv02_1 = nn.Conv2d(64, 128, 3, 2, 1)
        self.conv02_2 = nn.Conv2d(128, 128, 3, 1, 1)
        self.in02_1 = norm(128)
        self.conv03_1 = nn.Conv2d(128, 256, 3, 2, 1)
        self.conv03_2 = nn.Conv2d(256, 256, 3, 1, 1)
        self.in03_1 = norm(256)
        for block in range(4, 12):
            for half in (1, 2):
                setattr(self, f"refpad{block:02d}_{half}", nn.ReflectionPad2d(1))
                setattr(self, f"conv{block:02d}_{half}", nn.Conv2d(256, 256, 3))
                setattr(self, f"in{block:02d}_{half}", norm(256))
        self.deconv01_1 = nn.ConvTranspose2d(256, 128, 3, 2, 1, 1)
        self.deconv01_2 = nn.Conv2d(128, 128, 3, 1, 1)
        self.in12_1 = norm(128)
        self.deconv02_1 = nn.ConvTranspose2d(128, 64, 3, 2, 1, 1)
        self.deconv02_2 = nn.Conv2d(64, 64, 3, 1, 1)
        self.in13_1 = norm(64)
        self.refpad12_1 = nn.ReflectionPad2d(3)
        self.deconv03_1 = nn.Conv2d(64, 3, 7)

    def forward(self, x):
        y = F.relu(self.in01_1(self.conv01_1(self.refpad01_1(x))))
        y = F.relu(self.in02_1(self.conv02_2(self.conv02_1(y))))
        t = F.relu(self.in03_1(self.conv03_2(self.conv03_1(y))))
        for block in range(4, 12):
            pad1, conv1, in1 = (getattr(self, f"{k}{block:02d}_1") for k in ("refpad", "conv", "in"))
            pad2, conv2, in2 = (getattr(self, f"{k}{block:02d}_2") for k in ("refpad", "conv", "in"))
            y = F.relu(in1(conv1(pad1(t))))
            t = in2(conv2(pad2(y))) + t
        y = F.relu(self.in12_1(self.deconv01_2(self.deconv01_1(t))))
        y = F.relu(self.in13_1(self.deconv02_2(self.deconv02_1(y))))
        return torch.tanh(self.deconv03_1(self.refpad12_1(y)))


def load_generator(path, eps=1e-5):
    state = torch.load(path, map_location="cpu")
    renamed = {}
    for key, value in state.items():
        key = key.replace(".scale", ".weight").replace(".shift", ".bias")
        renamed[key] = value
    model = Generator(eps=eps)
    model.load_state_dict(renamed, strict=True)
    return model.eval()


class Packaged(nn.Module):
    """BGR 0...255 in, BGR 0...255 out. Core ML hands image inputs over as 0...255 floats."""

    def __init__(self, generator):
        super().__init__()
        self.generator = generator

    def forward(self, image):
        x = image / 127.5 - 1.0
        y = self.generator(x)
        return torch.clamp((y + 1.0) * 127.5, 0.0, 255.0)


def stylize_rgb(model, rgb):
    """`rgb` is HxWx3 uint8. Same preprocessing as the packaged model."""
    bgr = rgb[:, :, ::-1].astype(np.float32)
    tensor = torch.from_numpy(bgr.copy()).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        out = Packaged(model)(tensor)[0].permute(1, 2, 0).numpy()
    return np.clip(out[:, :, ::-1], 0, 255).astype(np.uint8)


# Width x height. Similar pixel counts, so every shape costs about the same; the app picks the one
# closest to the hand window's aspect instead of squashing the crop. All are multiples of 32.
SHAPES = [(384, 384), (320, 448), (448, 320), (256, 576), (576, 256)]


def convert(model, size, out_dir):
    import coremltools as ct

    width, height = size
    example = torch.rand(1, 3, height, width) * 255
    traced = torch.jit.trace(Packaged(model).eval(), example)
    shapes = ct.EnumeratedShapes(
        shapes=[(1, 3, h, w) for (w, h) in SHAPES],
        default=(1, 3, height, width),
    )
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=shapes, color_layout=ct.colorlayout.BGR)],
        outputs=[ct.ImageType(name="stylized", color_layout=ct.colorlayout.BGR)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.author = "CartoonGAN (Chen et al., CVPR 2018); PyTorch port by Yijun Li; packaged for Postcam"
    mlmodel.license = "MIT (CartoonGAN-Test-Pytorch-Torch, AnimeBackgroundGAN-Shinkai)"
    mlmodel.short_description = (
        "Photo to Makoto Shinkai style anime background. BGR in and out, same size; sizes: "
        + ", ".join(f"{w}x{h}" for (w, h) in SHAPES)
    )
    path = os.path.join(out_dir, "SonnyBoyAnime.mlpackage")
    mlmodel.save(path)
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--width", type=int, default=384)
    parser.add_argument("--height", type=int, default=384)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    model = load_generator(args.weights)
    print("saved", convert(model, (args.width, args.height), args.out))


if __name__ == "__main__":
    main()
