"""Rewrite the MOSS Nano global decode/prefill graphs to keep the KV cache in attention layout.

The exported decode step casts every past key/value float->float twice, concatenates the new
row, transposes the whole cache for the attention MatMul and casts it once more for the
output. On Quest that is ~5 full copies of every layer's cache per generated frame. Here:

* past_key_i is stored as [batch, heads, head_dim, seq] and past_value_i as
  [batch, heads, seq, head_dim], exactly what the attention MatMuls consume;
* only the new single-row key/value is transposed;
* the no-op Casts disappear; the Concat output is the present_* output itself.

Weights are untouched (the .data file is shared); the prefill graph gets matching output
transposes.

It also writes moss_tts_extend.onnx: the same decode graph taught to take several new rows per
call with a real causal mask and per-row rotary positions (the exported decode step reads one
scalar position and one scalar mask limit, so it is only correct for a single row). With it a
voice's prompt prefix is prefilled once and each sentence only runs its own text rows.

Both local-frame graphs also get a `continue_probability` output: the graph samples "continue" with
probability p = softmax(slot, end)[0] and stops when its random draw exceeds p, so INT8 noise that flattens
the end-of-speech peak makes the draw miss it. The engine reads 1 - p to stop at the first likely end.

Usage: optimize_kv_layout.py <model dir> <output dir>
"""
import collections
import copy
import os
import shutil
import sys

import onnx
import onnx.numpy_helper
from onnx import TensorProto, helper

PERM_K = [0, 2, 3, 1]  # [b,s,h,d] -> [b,h,d,s]
PERM_V = [0, 2, 1, 3]  # [b,s,h,d] -> [b,h,s,d]


def index(graph):
    consumers = collections.defaultdict(list)
    producers = {}
    for node in graph.node:
        for name in node.input:
            consumers[name].append(node)
        for name in node.output:
            producers[name] = node
    return consumers, producers


def set_value_shape(value, dims):
    del value.type.tensor_type.shape.dim[:]
    for dim in dims:
        item = value.type.tensor_type.shape.dim.add()
        if isinstance(dim, str):
            item.dim_param = dim
        else:
            item.dim_value = dim


def attribute(node, name):
    for item in node.attribute:
        if item.name == name:
            return list(item.ints) if item.ints else item.i
    return None


def rewrite_decode(model, layers=12, heads=12, head_dim=64):
    graph = model.graph
    consumers, producers = index(graph)
    remove = set()
    new_nodes = []
    front = []
    constants = {n.output[0]: n for n in graph.node if n.op_type == "Constant"}
    outputs = {o.name: o for o in graph.output}
    inputs = {i.name: i for i in graph.input}
    for layer in range(layers):
        for kind in ("key", "value"):
            past, present = f"past_{kind}_{layer}", f"present_{kind}_{layer}"
            chain = consumers[past]
            assert len(chain) == 1 and chain[0].op_type == "Cast", past
            first = chain[0]
            second = consumers[first.output[0]]
            assert len(second) == 1 and second[0].op_type == "Cast", past
            concat = consumers[second[0].output[0]]
            assert len(concat) == 1 and concat[0].op_type == "Concat" and attribute(concat[0], "axis") == 1, past
            concat = concat[0]
            assert list(concat.input)[0] == second[0].output[0]
            users = consumers[concat.output[0]]
            transposes = [n for n in users if n.op_type == "Transpose"]
            shapes = [n for n in users if n.op_type == "Shape"]
            casts = [n for n in users if n.op_type == "Cast"]
            assert len(transposes) == 1 and len(casts) == 1 and len(users) == len(shapes) + 2, (past, [u.op_type for u in users])
            transpose, cast_out = transposes[0], casts[0]
            assert cast_out.output[0] == present
            perm = PERM_K if kind == "key" else PERM_V
            assert attribute(transpose, "perm") == perm, (past, attribute(transpose, "perm"))
            fresh = list(concat.input)[1]
            moved = fresh + "_cache_layout"
            new_nodes.append(helper.make_node("Transpose", [fresh], [moved], name=f"/KvLayout/{kind}_{layer}", perm=perm))
            axis = 3 if kind == "key" else 2
            old_axis = concat.output[0]
            # Concat reads the graph input directly and writes the present output.
            del concat.input[:]
            concat.input.extend([past, moved])
            for item in concat.attribute:
                if item.name == "axis":
                    item.i = axis
            concat.output[0] = present
            # Attention MatMul consumes the cache as-is.
            for node in consumers[transpose.output[0]]:
                for position, name in enumerate(node.input):
                    if name == transpose.output[0]:
                        node.input[position] = present
            for node in shapes:
                # The sequence length of the cache is now at `axis`; the Shape consumer gathers dim 1.
                gather = consumers[node.output[0]]
                assert len(gather) == 1 and gather[0].op_type == "Gather", past
                node.input[0] = present
                index_name = gather[0].input[1]
                assert index_name in constants, index_name
                value = constants[index_name].attribute[0].t
                assert onnx.numpy_helper.to_array(value).item() == 1, index_name
                # A private constant: the original may be shared with other gathers.
                axis_name = f"/KvLayout/seq_axis_{kind}_{layer}"
                front.append(helper.make_node("Constant", [], [axis_name], name=axis_name,
                                              value=helper.make_tensor("value", TensorProto.INT64, [], [axis])))
                gather[0].input[1] = axis_name
            remove.update(id(n) for n in (first, second[0], transpose, cast_out))
            dims = ["batch", heads, head_dim, "past_seq"] if kind == "key" else ["batch", heads, "past_seq", head_dim]
            set_value_shape(inputs[past], dims)
            set_value_shape(outputs[present], [d if d != "past_seq" else "total_seq" for d in dims])
            del old_axis
    kept = [n for n in graph.node if id(n) not in remove]
    # New nodes must precede their consumers; the fresh row is produced earlier in the graph.
    position = {}
    for i, node in enumerate(kept):
        for name in node.output:
            position[name] = i
    del graph.node[:]
    pending = list(new_nodes)
    emitted = []
    for i, node in enumerate(kept):
        emitted.append(node)
    # Place each transpose right after the producer of its input.
    by_input = {n.input[0]: n for n in pending}
    final = list(front)
    for node in emitted:
        final.append(node)
        for name in node.output:
            if name in by_input:
                final.append(by_input.pop(name))
    assert not by_input, list(by_input)
    graph.node.extend(final)


def build_extend(decode):
    """Multi-row variant of the (already layout-rewritten) decode graph."""
    model = copy.deepcopy(decode)
    graph = model.graph
    consumers, producers = index(graph)
    position = [n for n in graph.node if n.name == "/Cast_44"]
    assert len(position) == 1
    base = position[0].output[0]  # [batch, 1] int64: the single scalar position of the decode step
    rows = "/Extend/rows"
    new = [
        helper.make_node("Shape", ["input_ids"], ["/Extend/ids_shape"], name="/Extend/ids_shape"),
        helper.make_node("Gather", ["/Extend/ids_shape", "/Extend/one"], [rows], name=rows, axis=0),
        helper.make_node("Range", ["/Extend/zero", rows, "/Extend/one"], ["/Extend/range"], name="/Extend/range"),
        helper.make_node("Unsqueeze", ["/Extend/range", "/Extend/axis0"], ["/Extend/range_row"], name="/Extend/range_row"),
        helper.make_node("Add", [base, "/Extend/range_row"], ["/Extend/positions"], name="/Extend/positions"),
        helper.make_node("Unsqueeze", ["/Extend/positions", "/Extend/axes13"], ["/Extend/query_positions"], name="/Extend/query_positions"),
    ]
    constants = [
        helper.make_node("Constant", [], ["/Extend/zero"], name="/Extend/zero", value=helper.make_tensor("v", TensorProto.INT64, [], [0])),
        helper.make_node("Constant", [], ["/Extend/one"], name="/Extend/one", value=helper.make_tensor("v", TensorProto.INT64, [], [1])),
        helper.make_node("Constant", [], ["/Extend/axis0"], name="/Extend/axis0", value=helper.make_tensor("v", TensorProto.INT64, [1], [0])),
        helper.make_node("Constant", [], ["/Extend/axes13"], name="/Extend/axes13", value=helper.make_tensor("v", TensorProto.INT64, [2], [1, 3])),
    ]
    # Rotary positions: every consumer of the scalar position now sees [batch, rows].
    for node in consumers[base]:
        for i, name in enumerate(node.input):
            if name == base:
                node.input[i] = "/Extend/positions"
    # Causal mask: row i sees keys <= past + i; the length bound becomes past + rows.
    constants_by_output = {n.output[0]: n for n in graph.node if n.op_type == "Constant"}
    less = [n for n in graph.node if n.op_type == "Less"]
    less_equal = [n for n in graph.node if n.op_type == "LessOrEqual"]
    assert len(less) == len(less_equal) == 12, (len(less), len(less_equal))
    for node in less_equal:
        node.input[1] = "/Extend/query_positions"
    for node in less:
        limit = producers[node.input[1]]
        assert limit.op_type == "Add", limit.op_type
        for i, name in enumerate(limit.input):
            if name in constants_by_output:
                assert onnx.numpy_helper.to_array(constants_by_output[name].attribute[0].t).item() == 1
                limit.input[i] = rows
    # The old per-layer [batch,1,1,1] position reshapes are dead now and would fail on several rows.
    live = {o.name for o in graph.output}
    nodes = list(graph.node)
    while True:
        used = set(live)
        for node in nodes + new:
            used.update(node.input)
        kept = [n for n in nodes if any(o in used for o in n.output)]
        if len(kept) == len(nodes):
            break
        nodes = kept
    split = next(i for i, n in enumerate(nodes) if n.name == "/Cast_44") + 1  # the new rows need the base position
    del graph.node[:]
    graph.node.extend(constants + nodes[:split] + new + nodes[split:])
    # The exported intermediate shapes say "one row"; stale hints make ORT fold the reshapes to 1.
    del graph.value_info[:]
    graph.name = graph.name + "_extend"
    return model


def expose_continue_probability(model):
    """Add the probability that the local graph compares its random draw with as the `continue_probability` output."""
    graph = model.graph
    producers = {name: n for n in graph.node for name in n.output}
    node = producers["should_continue"]
    while node.op_type != "LessOrEqual":  # should_continue = Reshape(Cast(LessOrEqual(draw, probability)))
        assert node.op_type in ("Reshape", "Cast"), node.op_type
        node = producers[node.input[0]]
    compare = [node]
    graph.node.append(helper.make_node("Identity", [compare[0].input[1]], ["continue_probability"], name="/EosProbability/identity"))
    output = graph.output.add()
    output.name = "continue_probability"
    output.type.tensor_type.elem_type = TensorProto.FLOAT
    output.type.tensor_type.shape.dim.add().dim_param = "batch"


def rewrite_prefill(model, layers=12):
    graph = model.graph
    consumers, producers = index(graph)
    outputs = {o.name: o for o in graph.output}
    tail = []
    for layer in range(layers):
        for kind, perm in (("key", PERM_K), ("value", PERM_V)):
            name = f"present_{kind}_{layer}"
            producer = producers[name]
            raw = name + "_sequence_layout"
            for position, item in enumerate(producer.output):
                if item == name:
                    producer.output[position] = raw
            for node in consumers[name]:
                for position, item in enumerate(node.input):
                    if item == name:
                        node.input[position] = raw
            tail.append(helper.make_node("Transpose", [raw], [name], name=f"/KvLayout/prefill_{kind}_{layer}", perm=perm))
            dims = ["batch", 12, 64, "prefill_seq"] if kind == "key" else ["batch", 12, "prefill_seq", 64]
            set_value_shape(outputs[name], dims)
    graph.node.extend(tail)  # graph outputs only; nothing downstream depends on order


def main():
    source, target = sys.argv[1], sys.argv[2]
    tts = os.path.join(source, "MOSS-TTS-Nano-100M-ONNX")
    out = os.path.join(target, "MOSS-TTS-Nano-100M-ONNX")
    os.makedirs(out, exist_ok=True)
    for name in os.listdir(tts):
        if name in ("moss_tts_decode_step.onnx", "moss_tts_prefill.onnx", "moss_tts_local_fixed_sampled_frame.onnx", "moss_tts_local_fallback.onnx"):
            continue
        destination = os.path.join(out, name)
        if not os.path.exists(destination):
            shutil.copy2(os.path.join(tts, name), destination)  # not a hard link: onnx refuses those
    codec = os.path.join(target, "MOSS-Audio-Tokenizer-Nano-ONNX")
    if not os.path.exists(codec):
        os.makedirs(codec)
        for name in os.listdir(os.path.join(source, "MOSS-Audio-Tokenizer-Nano-ONNX")):
            src = os.path.join(source, "MOSS-Audio-Tokenizer-Nano-ONNX", name)
            shutil.copy2(src, os.path.join(codec, name))
    for file, rewrite in (("moss_tts_decode_step.onnx", rewrite_decode), ("moss_tts_prefill.onnx", rewrite_prefill),
                          ("moss_tts_local_fixed_sampled_frame.onnx", expose_continue_probability),
                          ("moss_tts_local_fallback.onnx", expose_continue_probability)):
        model = onnx.load(os.path.join(tts, file), load_external_data=False)
        rewrite(model)
        onnx.save_model(model, os.path.join(out, file))
        onnx.checker.check_model(os.path.join(out, file))  # by path: external data resolves next to the file
        print("wrote", file, len(model.graph.node), "nodes")
        if file == "moss_tts_decode_step.onnx":
            extend = build_extend(model)
            onnx.save_model(extend, os.path.join(out, "moss_tts_extend.onnx"))
            onnx.checker.check_model(os.path.join(out, "moss_tts_extend.onnx"))
            print("wrote moss_tts_extend.onnx", len(extend.graph.node), "nodes")


if __name__ == "__main__":
    main()
