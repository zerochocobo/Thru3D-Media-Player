"""Build the video or independent still-photo MNN depth model on Quest.

Source: Depth Anything V2 Small (Apache-2.0), the ONNX export from
onnx-community/depth-anything-v2-small. The existing Quest pipeline uses this
DINOv2 ViT-S + DPT model with measured OpenCL timings below. Those timings do
not establish whether DA3 Small is suitable; that export needs its own
backend-specific validation and benchmark.

The video graph uses a small 16:9 input; --photo builds a separate 518x518
graph for orientation-preserving letterboxed photos. Each shape is frozen
(multiples of the 14 px patch) so every
shape computation and the position-embedding interpolation fold into
constants; MNN then has no bicubic resize or dynamic shape ops to place on the
CPU. Inputs are the render bridge's float32 CHW RGB in [0, 1]; ImageNet
normalization is folded into the first ops. The output is DAv2's relative
inverse depth (larger = nearer); the runtime maps it to a 0..1 near map.

Checks: the frozen graph against the ORT graph of the converted network (late-upsample head) on real frames, and
the converted MNN model (CPU, FP32) against the frozen graph.
"""
import os
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'models/source/depth/depth_anything_v2_small.onnx'
OUT = ROOT / 'build/depth'
ASSETS = ROOT / 'android/player-plugin/src/main/assets/depth-mnn'
MNNCONVERT = Path(os.environ.get('MNNCONVERT', 'mnnconvert'))
SAMPLES = [OUT / 'sample_a.png', OUT / 'sample_b.png']
# Fixed 364x210 video input; runtime performance depends on source and headset.
WIDTH, HEIGHT = 364, 210
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def frames(width, height):
    """Real frames as float32 CHW [0, 1], resized like the bridge (bilinear)."""
    from PIL import Image
    out = []
    for path in SAMPLES:
        image = Image.open(path).convert('RGB').resize((width, height), Image.BILINEAR)
        out.append(np.asarray(image, np.float32).transpose(2, 0, 1)[None] / 255.0)
    rng = np.random.default_rng(7)
    out.append(rng.random((1, 3, height, width), dtype=np.float32))
    return out


def late_upsample(model):
    """DPT head: run the last 3x3 (32->32) and 1x1 (32->1) convolutions at the 2x feature size and
    upsample the 1-channel result (same bilinear align_corners Resize) instead of upsampling the
    32-channel map first. DIODE accuracy is unchanged at 252..518 px; Quest 3 time -2..3%."""
    g = model.graph
    by_name = {n.name: n for n in g.node}
    resize = by_name['/depth_head/Resize']
    by_name['/depth_head/output_conv2/output_conv2.0/Conv'].input[0] = resize.input[0]
    small = by_name['/depth_head/output_conv2/output_conv2.3/Relu'].output[0]
    target_hw = by_name['/depth_head/Concat_5'].input[1]
    g.initializer.extend([numpy_helper.from_array(np.array([0], np.int64), 'late_s0'),
                          numpy_helper.from_array(np.array([2], np.int64), 'late_s2')])
    added = [
        helper.make_node('Shape', [small], ['late_shape'], name='late_shape'),
        helper.make_node('Slice', ['late_shape', 'late_s0', 'late_s2'], ['late_nc'], name='late_slice'),
        helper.make_node('Concat', ['late_nc', target_hw], ['late_sizes'], axis=0, name='late_concat'),
        helper.make_node('Resize', [small, '', '', 'late_sizes'], ['late_up'], name='late_resize',
                         **{a.name: helper.get_attribute_value(a) for a in resize.attribute}),
    ]
    final = by_name['/Relu']
    final.input[0] = 'late_up'
    position = list(g.node).index(final)
    for offset, node in enumerate(added):
        g.node.insert(position + offset, node)
    g.node.remove(resize)
    del g.value_info[:]  # shapes recorded for the full-size head
    return model


def source_model():
    """The converted network: the published ONNX with the late-upsample head."""
    return late_upsample(onnx.load(str(SOURCE)))


def freeze(width, height):
    from onnxsim import simplify
    model = source_model()
    graph = model.graph
    original = graph.input[0].name
    # src (0..1) -> (src - mean) / std == src * (1/std) + (-mean/std): one Mul + Add.
    graph.initializer.extend([
        numpy_helper.from_array((1.0 / STD).reshape(1, 3, 1, 1), 'src_scale'),
        numpy_helper.from_array((-MEAN / STD).reshape(1, 3, 1, 1), 'src_bias'),
    ])
    del graph.input[:]
    graph.input.extend([helper.make_tensor_value_info('src', TensorProto.FLOAT, [1, 3, height, width])])
    graph.node.insert(0, helper.make_node('Add', ['src_scaled', 'src_bias'], [original], name='src_normalize_bias'))
    graph.node.insert(0, helper.make_node('Mul', ['src', 'src_scale'], ['src_scaled'], name='src_normalize_scale'))
    # (1, H, W) -> (1, 1, H, W) named depth: NCHW like every other model output in the runtime.
    produced = graph.output[0].name
    graph.initializer.append(numpy_helper.from_array(np.array([1, 1, height, width], np.int64), 'depth_shape'))
    graph.node.append(helper.make_node('Reshape', [produced, 'depth_shape'], ['depth'], name='depth_nchw'))
    del graph.output[:]
    graph.output.extend([helper.make_tensor_value_info('depth', TensorProto.FLOAT, [1, 1, height, width])])
    simplified, ok = simplify(model)
    if not ok:
        raise SystemExit('onnxsim could not validate the frozen depth graph')
    left = sorted({n.op_type for n in simplified.graph.node} & {'Shape', 'Gather', 'Resize', 'Where', 'Expand', 'Equal'})
    return simplified, left


def split_patch_embedding(model, width, height):
    """MNN OpenCL has no kernel for the ViT's 14x14 stride-14 patch convolution and places it on
    the CPU (the runtime rejects that). The same layer as GPU ops: cut the frame into 14x14
    patches with Reshape/Transpose (channel = c*196 + kh*14 + kw), then a 1x1 convolution
    whose weights are the original kernel flattened in that order."""
    graph = model.graph
    inits = {i.name: i for i in graph.initializer}
    for index, node in enumerate(graph.node):
        attrs = {a.name: helper.get_attribute_value(a) for a in node.attribute}
        if node.op_type != 'Conv' or attrs.get('kernel_shape') != [14, 14] or attrs.get('strides') != [14, 14]:
            continue
        weight = numpy_helper.to_array(inits[node.input[1]])
        out_c, in_c, k, _ = weight.shape
        gh, gw = height // k, width // k
        name = node.name.replace('/', '_')
        graph.initializer.extend([
            numpy_helper.from_array(np.array([1, in_c, gh, k, gw, k], np.int64), name + '_grid'),
            numpy_helper.from_array(np.array([1, in_c * k * k, gh, gw], np.int64), name + '_patches'),
            numpy_helper.from_array(weight.reshape(out_c, in_c * k * k, 1, 1), name + '_w1x1'),
        ])
        replacement = [
            helper.make_node('Reshape', [node.input[0], name + '_grid'], [name + '_grid_out'], name=name + '_grid'),
            helper.make_node('Transpose', [name + '_grid_out'], [name + '_t'], perm=[0, 1, 3, 5, 2, 4], name=name + '_t'),
            helper.make_node('Reshape', [name + '_t', name + '_patches'], [name + '_patches_out'], name=name + '_patches'),
            helper.make_node('Conv', [name + '_patches_out', name + '_w1x1'] + list(node.input[2:]), list(node.output),
                             kernel_shape=[1, 1], name=name + '_1x1'),
        ]
        del graph.node[index]
        for offset, new in enumerate(replacement):
            graph.node.insert(index + offset, new)
        return 1
    return 0


def split_attention_heads(model):
    """Each block reshapes its fused q/k/v projection to 5D [1, N, 3, heads, d], transposes and
    picks q, k and v with Gathers: MNN OpenCL (image memory) lays out at most 4D, so these copies
    ran on the CPU. Same values in 4D: slice the projection's last axis into q, k and v, then
    Reshape [1, N, heads, d] and Transpose to [1, heads, N, d] for the Gathers' consumers."""
    graph = model.graph
    inits = {i.name: i for i in graph.initializer}
    producers = {o: n for n in graph.node for o in n.output}
    consumers = {}
    for n in graph.node:
        for i in n.input:
            consumers.setdefault(i, []).append(n)
    rewritten = 0
    for reshape in list(graph.node):
        if reshape.op_type != 'Reshape' or reshape.input[1] not in inits:
            continue
        target = numpy_helper.to_array(inits[reshape.input[1]]).tolist()
        if len(target) != 5 or target[2] != 3:
            continue
        transposes = consumers.get(reshape.output[0], [])
        if len(transposes) != 1 or transposes[0].op_type != 'Transpose' or \
                [a.ints for a in transposes[0].attribute if a.name == 'perm'][0] != [2, 0, 3, 1, 4]:
            continue
        transpose = transposes[0]
        gathers = consumers.get(transpose.output[0], [])
        picks = {}
        for gather in gathers:
            index = numpy_helper.to_array(inits[gather.input[1]]) if gather.input[1] in inits else None
            if gather.op_type != 'Gather' or index is None or index.size != 1:
                break
            picks[int(index)] = gather
        if sorted(picks) != [0, 1, 2] or len(gathers) != 3:
            continue
        _, tokens, _, heads, dim = target
        width = heads * dim
        base = reshape.name.replace('/', '_')
        graph.initializer.append(numpy_helper.from_array(np.array([1, tokens, heads, dim], np.int64), base + '_heads'))
        graph.initializer.append(numpy_helper.from_array(np.array([-1], np.int64), base + '_axis'))
        nodes = []
        for part in range(3):
            graph.initializer.extend([
                numpy_helper.from_array(np.array([part * width], np.int64), f'{base}_s{part}'),
                numpy_helper.from_array(np.array([(part + 1) * width], np.int64), f'{base}_e{part}'),
            ])
            out = picks[part].output[0]
            nodes += [
                helper.make_node('Slice', [reshape.input[0], f'{base}_s{part}', f'{base}_e{part}', base + '_axis'],
                                 [f'{base}_p{part}'], name=f'{base}_slice{part}'),
                helper.make_node('Reshape', [f'{base}_p{part}', base + '_heads'], [f'{base}_h{part}'], name=f'{base}_heads{part}'),
                helper.make_node('Transpose', [f'{base}_h{part}'], [out], perm=[0, 2, 1, 3], name=f'{base}_t{part}'),
            ]
        position = list(graph.node).index(reshape)
        for old in [reshape, transpose] + list(picks.values()):
            graph.node.remove(old)
        for offset, new in enumerate(nodes):
            graph.node.insert(position + offset, new)
        rewritten += 1
    return rewritten


def keep_layer_norm_ops(model):
    """MNN's Vulkan image backend has no LayerNorm kernel and the converter fuses the exported
    ReduceMean/Sub/Pow/... chain into one. Squaring with Mul(x, x) instead of Pow(x, 2) keeps the
    chain as reductions and elementwise ops, which that backend runs."""
    inits = {i.name: i for i in model.graph.initializer}
    rewritten = 0
    for node in model.graph.node:
        if node.op_type == 'Pow' and '/norm' in node.name and node.input[1] in inits and \
                float(numpy_helper.to_array(inits[node.input[1]])) == 2.0:
            node.op_type = 'Mul'
            node.input[1] = node.input[0]
            rewritten += 1
    return rewritten


def split_attention_matmul(model, heads=6):
    """After split_attention_heads. The [1, heads, N, d] attention products become MNN loops that
    its Vulkan image backend places on the CPU; it does run 2D MatMul. Same values per head, all 2D:
    slice q, k and v [N, d] from the fused projection [N, 3*heads*d], softmax(q k^T) v, and join the
    heads' columns into the [N, heads*d] tensor the output projection reads."""
    graph = model.graph
    by_name = {n.name: n for n in graph.node}
    inits = {i.name: i for i in graph.initializer}
    rewritten = 0
    for block in range(len([n for n in graph.node if n.name.endswith('/attn/Softmax')])):
        prefix, base = f'/blocks.{block}/attn/', f'_blocks.{block}_attn_Reshape'
        projection = by_name[base + '_slice0'].input[0]
        _, _, count, dim = numpy_helper.to_array(inits[base + '_heads']).tolist()
        if count != heads:
            raise SystemExit(f'Attention block {block} has {count} heads, expected {heads}')
        merged = [n for n in graph.node if n.op_type == 'Reshape' and n.input[0] == by_name[prefix + 'Transpose_2'].output[0]]
        if len(merged) != 1:
            raise SystemExit(f'Attention block {block} output is not one flattening Reshape')
        old = [by_name[f'{base}_{kind}{part}'] for part in range(3) for kind in ('slice', 'heads', 't')] + \
              [by_name[prefix + name] for name in ('Mul', 'Transpose_1', 'MatMul', 'Softmax', 'MatMul_1', 'Transpose_2')] + merged
        scale = by_name[prefix + 'Mul'].input[1]
        tag = f'_blocks.{block}_attn_head'
        graph.initializer.append(numpy_helper.from_array(np.array([1], np.int64), tag + '_axis'))
        nodes, outputs = [], []
        for head in range(heads):
            parts = []
            for part in range(3):
                start = (part * heads + head) * dim
                graph.initializer.extend([numpy_helper.from_array(np.array([start], np.int64), f'{tag}{head}_s{part}'),
                                          numpy_helper.from_array(np.array([start + dim], np.int64), f'{tag}{head}_e{part}')])
                nodes.append(helper.make_node('Slice', [projection, f'{tag}{head}_s{part}', f'{tag}{head}_e{part}', tag + '_axis'],
                                              [f'{tag}{head}_p{part}'], name=f'{tag}{head}_slice{part}'))
                parts.append(f'{tag}{head}_p{part}')
            name = f'{tag}{head}'
            nodes += [
                helper.make_node('Mul', [parts[0], scale], [name + '_q'], name=name + '_scale'),
                helper.make_node('Transpose', [parts[1]], [name + '_kt'], perm=[1, 0], name=name + '_kt'),
                helper.make_node('MatMul', [name + '_q', name + '_kt'], [name + '_scores'], name=name + '_scores'),
                helper.make_node('Softmax', [name + '_scores'], [name + '_weights'], axis=-1, name=name + '_softmax'),
                helper.make_node('MatMul', [name + '_weights', parts[2]], [name + '_out'], name=name + '_out'),
            ]
            outputs.append(name + '_out')
        nodes.append(helper.make_node('Concat', outputs, list(merged[0].output), axis=1, name=tag + '_join'))
        position = list(graph.node).index(old[0])
        for node in old:
            graph.node.remove(node)
        for offset, node in enumerate(nodes):
            graph.node.insert(position + offset, node)
        rewritten += 1
    return rewritten


def check_frozen(frozen_path, width, height):
    reference = ort.InferenceSession(source_model().SerializeToString(), providers=['CPUExecutionProvider'])
    frozen = ort.InferenceSession(str(frozen_path), providers=['CPUExecutionProvider'])
    worst = 0.0
    for src in frames(width, height):
        normalized = (src - MEAN.reshape(1, 3, 1, 1)) / STD.reshape(1, 3, 1, 1)
        a = reference.run(None, {reference.get_inputs()[0].name: normalized})[0]
        b = frozen.run(None, {'src': src})[0]
        worst = max(worst, float(np.max(np.abs(a.reshape(b.shape) - b)) / max(1e-6, float(np.max(np.abs(a))))))
    return worst


def check_mnn(mnn_path, frozen_path, width, height):
    import MNN
    frozen = ort.InferenceSession(str(frozen_path), providers=['CPUExecutionProvider'])
    interpreter = MNN.Interpreter(str(mnn_path))
    session = interpreter.createSession({'precision': 'high'})
    src_tensor = interpreter.getSessionInput(session, 'src')
    worst = 0.0
    for src in frames(width, height):
        expected = frozen.run(None, {'src': src})[0]
        host = MNN.Tensor((1, 3, height, width), MNN.Halide_Type_Float, src.copy(), MNN.Tensor_DimensionType_Caffe)
        src_tensor.copyFrom(host)
        interpreter.runSession(session)
        output = interpreter.getSessionOutput(session, 'depth')
        result = MNN.Tensor(output.getShape(), MNN.Halide_Type_Float,
                            np.zeros(expected.shape, np.float32), MNN.Tensor_DimensionType_Caffe)
        output.copyToHostTensor(result)
        got = np.array(result.getData(), np.float32).reshape(expected.shape)
        worst = max(worst, float(np.max(np.abs(got - expected)) / max(1e-6, float(np.max(np.abs(expected))))))
    return worst


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--width', type=int, default=WIDTH)
    parser.add_argument('--height', type=int, default=HEIGHT)
    parser.add_argument('--install', action='store_true', help='copy the verified model into the plugin assets')
    parser.add_argument('--photo', action='store_true', help='build the independent 518x518 still-photo model; never replace the video asset')
    parser.add_argument('--vulkan', action='store_true', help='with --photo: build the separate graph for headsets whose GPU backend is Vulkan; never replace the OpenCL photo asset')
    args = parser.parse_args()
    width, height = args.width, args.height
    if args.vulkan and not args.photo:
        raise SystemExit('--vulkan builds the still-photo model only: pass --photo')
    if args.photo:
        width, height = 518, 518
    elif width <= 0 or height <= 0 or width % 14 or height % 14 or width % 2 or height % 2 or width > 512 or height > 512:
        raise SystemExit('Depth input must be even multiples of 14, at most 512 (render bridge limit)')
    OUT.mkdir(parents=True, exist_ok=True)
    key = f'{width}x{height}'
    frozen, leftovers = freeze(width, height)
    if split_patch_embedding(frozen, width, height) != 1:
        raise SystemExit('Patch embedding convolution not found')
    blocks = split_attention_heads(frozen)
    if blocks != 12:
        raise SystemExit(f'Expected 12 attention blocks to split, found {blocks}')
    if args.vulkan:
        # Quest 2 (Adreno 650, Vulkan FP32, 2026-11-18): every op on the GPU, 3.1 s a photo, within 1.2%
        # of the frozen graph's largest value; the OpenCL asset placed 52 LayerNorm/attention ops on the CPU.
        key += '_vulkan'
        norms, products = keep_layer_norm_ops(frozen), split_attention_matmul(frozen)
        if norms != 25 or products != 12:
            raise SystemExit(f'Expected 25 layer norms and 12 attention blocks for Vulkan, found {norms} and {products}')
    frozen_path = OUT / f'depth_{key}.onnx'
    onnx.save(frozen, str(frozen_path))
    frozen_error = check_frozen(frozen_path, width, height)
    if frozen_error > 1e-4:
        raise SystemExit(f'Frozen depth graph differs from the source: {frozen_error}')
    mnn_path = OUT / f'depth_{key}.mnn'
    log = subprocess.run([str(MNNCONVERT), '-f', 'ONNX', '--modelFile', str(frozen_path), '--MNNModel', str(mnn_path),
                          '--bizCode', 'depth', '--fp16'], capture_output=True, text=True)
    if log.returncode != 0 or not mnn_path.is_file():
        raise SystemExit('mnnconvert failed:\n' + log.stdout + log.stderr)
    mnn_error = check_mnn(mnn_path, frozen_path, width, height)
    if mnn_error > 0.02:  # FP16 weights; relative to the largest output value
        raise SystemExit(f'MNN depth model differs from the frozen graph: {mnn_error}')
    mnn_file = 'photo_depth_vulkan.mnn' if args.vulkan else 'photo_depth.mnn' if args.photo else 'depth.mnn'
    manifest = dict(schema_version=2, backend='MNN 3.6.1 Vulkan' if args.vulkan else 'MNN 3.6.1 OpenCL', model='Depth Anything V2 Small', head='late-upsample',
                    license='Apache-2.0', source_onnx=str(SOURCE.relative_to(ROOT)), source_sha256=sha(SOURCE),
                    input='src float32 1x3xHxW RGB 0..1 (ImageNet normalization folded)',
                    output='depth float32 1x1xHxW relative inverse depth (larger = nearer)',
                    width=width, height=height, frozen_onnx_sha256=sha(frozen_path), mnn_sha256=sha(mnn_path),
                    mnn_file=mnn_file, usage='photo' if args.photo else 'video', dynamic_ops_left=leftovers,
                    frozen_vs_source_rel_max=frozen_error, mnn_fp16_weights_vs_frozen_rel_max=mnn_error)
    (OUT / f'manifest_{key}.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(manifest, indent=2))
    if args.install:
        ASSETS.mkdir(parents=True, exist_ok=True)
        (ASSETS / manifest['mnn_file']).write_bytes(mnn_path.read_bytes())
        manifest_file = 'photo_vulkan_manifest.json' if args.vulkan else 'photo_manifest.json' if args.photo else 'manifest.json'
        (ASSETS / manifest_file).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        if args.vulkan:
            # The committed catalog lets a source checkout import and verify the ignored weights.
            catalog_path = ROOT / 'models/manifest/runtime-assets.json'
            catalog = json.loads(catalog_path.read_text(encoding='utf-8'))
            asset_path = 'depth-mnn/' + mnn_file
            catalog['assets'] = [entry for entry in catalog['assets'] if entry['path'] != asset_path]
            catalog['assets'].append(dict(path=asset_path, bytes=mnn_path.stat().st_size, sha256=manifest['mnn_sha256']))
            catalog['manifests']['photo-depth-vulkan-mnn'] = manifest
            catalog_path.write_text(json.dumps(catalog, indent=2) + '\n', encoding='utf-8')
        (ASSETS / 'LICENSE-DepthAnythingV2-Small.txt').write_bytes(
            (ROOT / 'models/licenses/DepthAnythingV2_Apache-2.0.txt').read_bytes())
        print(f'Installed depth model {manifest["mnn_sha256"][:12]} -> {ASSETS}')


if __name__ == '__main__':
    main()
