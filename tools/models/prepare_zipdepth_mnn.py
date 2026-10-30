"""Export pinned ZipDepth base with equivalent mobile operators and validate before install.

Run in the PyTorch environment; --mnn-python names the environment with MNN 3.6.1.
Source/checkpoint are local, reviewed copies of the revision below. No implicit downloads.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
REVISION = "91f3fd21e131641f51e8d35736d1958350180e3a"
CHECKPOINT_SHA = "a55910bb0b99c8c5e641cb9206e810b269690ad94e8a2ef08c827c4679391a65"
WIDTH, HEIGHT = 512, 288


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def relative_error(expected, actual):
    import numpy as np
    if expected.shape != actual.shape or not np.isfinite(actual).all():
        raise ValueError("Invalid model output")
    return float(np.max(np.abs(expected - actual)) / max(1e-6, float(np.max(np.abs(expected)))))


def verify_mnn(directory):
    import MNN
    import numpy as np
    import onnxruntime as ort
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    reference = ort.InferenceSession(str(directory / "zipdepth.onnx"), options)
    _, _, height, width = reference.get_inputs()[0].shape
    net = MNN.Interpreter(str(directory / "zipdepth.mnn"))
    session = net.createSession({"precision": "high", "numThread": 4})
    source = net.getSessionInput(session, "src")
    errors = []
    for path in sorted((directory / "inputs").glob("*.bin")):
        rgb = np.fromfile(path, np.float32).reshape(1, 3, height, width)
        source.copyFrom(MNN.Tensor(rgb.shape, MNN.Halide_Type_Float, rgb, MNN.Tensor_DimensionType_Caffe))
        net.runSession(session)
        output = net.getSessionOutput(session, "depth")
        expected = reference.run(None, {"src": rgb})[0]
        host = MNN.Tensor(output.getShape(), MNN.Halide_Type_Float, np.zeros(expected.shape, np.float32), MNN.Tensor_DimensionType_Caffe)
        output.copyToHostTensor(host)
        actual = np.array(host.getData(), np.float32).reshape(expected.shape)
        error = relative_error(expected, actual)
        if error > .02:
            raise ValueError(f"MNN FP16 weight error exceeds 2%: {path.name}: {error}")
        errors.append({"input": path.name, "relative_max": error})
    if len(errors) < 5:
        raise ValueError("Need four real images and a noise input")
    write_json(directory / "mnn-check.json", errors)


def main():
    global WIDTH, HEIGHT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "models/source/depth/zipdepth")
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--images", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, default=ROOT / "build/models/zipdepth")
    parser.add_argument("--mnn-python", type=Path)
    parser.add_argument("--mnnconvert", type=Path)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--compatible", action="store_true", help="384x224 graph for older/unknown headsets")
    parser.add_argument("--verify-mnn", type=Path)
    args = parser.parse_args()
    if args.compatible:
        WIDTH, HEIGHT = 384, 224
    if args.verify_mnn:
        verify_mnn(args.verify_mnn)
        return
    if not args.images or len(args.images) < 4 or not args.mnn_python or not args.mnnconvert:
        parser.error("Supply at least four real --images, --mnn-python and --mnnconvert")
    import numpy as np
    import onnx
    import onnxruntime as ort
    from PIL import Image
    import torch
    from zipdepth_mobile import adapt
    torch.set_num_threads(4)
    checkpoint = args.checkpoint or args.source / "checkpoints/zipdepth_base.pth"
    if sha(checkpoint) != CHECKPOINT_SHA:
        raise ValueError("Unexpected ZipDepth base checkpoint")
    if (args.source / "reviewed-commit.txt").read_text().strip() != REVISION:
        raise ValueError("Unexpected reviewed ZipDepth revision")
    arch_path = args.source / "zipdepth/model/architecture.py"
    utils_path = args.source / "zipdepth/utils/model_utils.py"
    if sha(arch_path) != "9fd74fa2053da5bd56b2f2eecfdc3a6bf5e5161da0df05c72da3b89f29b77521" or sha(utils_path) != "cd396c8d4f1eeb93da564b879d2b62aee8025d11222188153a549457649ead5c":
        raise ValueError("Reviewed source bytes differ")
    arch = load_module("zipdepth_arch", arch_path)
    utils = load_module("zipdepth_utils", utils_path)
    model = arch.create_model(variant="base", global_mode="balanced", upsample_unfold=True).eval()
    checkpoint_data = torch.load(checkpoint, map_location="cpu", weights_only=True)
    model.load_state_dict(utils.strip_state_dict_prefixes(checkpoint_data.get("model_state_dict", checkpoint_data)), strict=True)
    mobile = copy.deepcopy(model).fuse_for_inference()
    utils.fuse_remaining_conv_bn(mobile)
    mobile = adapt(mobile)
    out = args.output
    (out / "inputs").mkdir(parents=True, exist_ok=True)
    inputs = []
    for path in args.images:
        with Image.open(path) as image:
            rgb = np.asarray(image.convert("RGB").resize((WIDTH, HEIGHT), Image.Resampling.BILINEAR)).copy()
        inputs.append((path.name, rgb.transpose(2, 0, 1)[None].astype(np.float32) / 255))
    inputs.append(("seed42-noise", np.random.default_rng(42).random((1, 3, HEIGHT, WIDTH), dtype=np.float32)))
    errors = []
    with torch.inference_mode():
        for index, (name, rgb) in enumerate(inputs):
            rgb.tofile(out / "inputs" / f"{index:02d}.bin")
            error = relative_error(model(torch.from_numpy(rgb)).numpy(), mobile(torch.from_numpy(rgb)).numpy())
            if error > 1e-4:
                raise ValueError(f"Mobile rewrite differs from the original: {name}: {error}")
            errors.append({"input": name, "rewrite_relative_max": error})
        torch.onnx.export(mobile, torch.from_numpy(inputs[0][1]), str(out / "zipdepth.onnx"),
                          input_names=["src"], output_names=["depth"], opset_version=17, dynamo=False)
        onnx.checker.check_model(onnx.load(out / "zipdepth.onnx"))
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        session = ort.InferenceSession(str(out / "zipdepth.onnx"), options)
        for record, (_, rgb) in zip(errors, inputs):
            error = relative_error(mobile(torch.from_numpy(rgb)).numpy(), session.run(None, {"src": rgb})[0])
            if error > 1e-4:
                raise ValueError(f"ONNX export differs: {error}")
            record["onnx_relative_max"] = error
    subprocess.run([str(args.mnnconvert), "-f", "ONNX", "--modelFile", str(out / "zipdepth.onnx"),
                    "--MNNModel", str(out / "zipdepth.mnn"), "--fp16", "--bizCode", "ZipDepthVideo"], check=True)
    subprocess.run([str(args.mnn_python), str(Path(__file__).resolve()), "--verify-mnn", str(out)], check=True)
    mnn_errors = json.loads((out / "mnn-check.json").read_text())
    manifest = dict(schema_version=3, backend="MNN 3.6.1 OpenCL", model="ZipDepth base", head="convex-softmax-free-clamp8, dense-grouped-1x1",
                    license="MIT", upstream="https://github.com/fabiotosi92/ZipDepth", revision=REVISION,
                    checkpoint_sha256=CHECKPOINT_SHA, architecture_sha256=sha(arch_path), model_utils_sha256=sha(utils_path),
                    input=f"src float32 1x3x{HEIGHT}x{WIDTH} RGB 0..1", output=f"depth float32 1x1x{HEIGHT}x{WIDTH} relative inverse depth (larger = nearer)",
                    width=WIDTH, height=HEIGHT, usage="video", mnn_file="depth_compat.mnn" if args.compatible else "depth.mnn", compute_precision="fp16",
                    weight_precision="fp16", gpu_mode=16, global_context="learned softmax (not mean approximation)",
                    frozen_onnx_sha256=sha(out / "zipdepth.onnx"), mnn_sha256=sha(out / "zipdepth.mnn"),
                    validation=errors, mnn_fp16_weights_vs_frozen_rel_max=max(e["relative_max"] for e in mnn_errors))
    write_json(out / "manifest.json", manifest)
    if args.install:
        assets = ROOT / "android/player-plugin/src/main/assets/depth-mnn"
        model_name = manifest["mnn_file"]
        manifest_name = "compat_manifest.json" if args.compatible else "manifest.json"
        if (assets / model_name).is_file():
            previous = json.loads((assets / manifest_name).read_text())
            backup = ROOT / "models/source/depth/previous" / previous["mnn_sha256"]
            backup.mkdir(parents=True, exist_ok=True)
            for name in (model_name, manifest_name):
                target = backup / name
                if target.exists() and sha(target) != sha(assets / name):
                    raise ValueError(f"Conflicting preserved model: {target}")
                shutil.copyfile(assets / name, target)
        shutil.copyfile(out / "zipdepth.mnn", assets / model_name)
        write_json(assets / manifest_name, manifest)
        write_json(ROOT / "models/manifest" / ("zipdepth_video_compat.json" if args.compatible else "zipdepth_video.json"), manifest)
        catalog_path = ROOT / "models/manifest/runtime-assets.json"
        catalog = json.loads(catalog_path.read_text())
        asset_path = "depth-mnn/" + model_name
        catalog["assets"] = [entry for entry in catalog["assets"] if entry["path"] != asset_path]
        catalog["assets"].append(dict(path=asset_path, bytes=(assets / model_name).stat().st_size, sha256=manifest["mnn_sha256"]))
        catalog["manifests"]["depth-compat-mnn" if args.compatible else "depth-mnn"] = manifest
        write_json(catalog_path, catalog)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
