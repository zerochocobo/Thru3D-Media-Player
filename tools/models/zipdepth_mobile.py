"""Equivalent four-dimensional ZipDepth operations for mobile GPU runtimes.

Reference model: fabiotosi92/ZipDepth, 91f3fd21e131641f51e8d35736d1958350180e3a (MIT).
The convex-head deployment approach also follows NeoNatural/xr-3d-viewer's
tools/convert_zipdepth.py at 283c0180af0f4a7c96e182bfcda7fdec12d7d143 (GPL-3.0).
Unlike that export, learned global-context weights are retained.
"""

import types

import torch
from torch import nn
from torch.nn import functional as F


class ConvexUpsample2D(nn.Module):
    """Convex upsampling without a Softmax operator.

    Mask channel c = k * S^2 + s (neighbour k, subpixel s), as the original's (9, S^2) view.
    MNN OpenCL lowers the 9-way channel softmax at full resolution to one ~8 ms kernel (Quest 3,
    512x288, of ~24 ms total), so it is spelled out with convolutions and elementwise ops:
    softmax is shift invariant, so the per-subpixel mean is subtracted inside the mask convolution's
    weights; Exp, then a 1x1 convolution that sums each subpixel's nine terms and broadcasts the sum
    back, normalizes the weights before they multiply depth (FP16 stays bounded). The centered
    logit is clamped at CLAMP (exp < 2981, a nine-term sum < 27k): on real frames it peaked at 9.05,
    where one neighbour already holds over 99.9% of the weight.
    """

    CLAMP = 8.0

    def __init__(self, source):
        super().__init__()
        self.scale = source.scale
        parts = list(source.mask_pred.children())
        self.features = nn.Sequential(*parts[:-1])
        last = parts[-1]
        sub = self.scale ** 2
        channels = 9 * sub
        group = torch.arange(channels) % sub
        same = (group[:, None] == group[None, :]).to(last.weight.dtype)  # same subpixel
        center = torch.eye(channels) - same / 9
        self.mask = nn.Conv2d(last.in_channels, channels, 1)
        with torch.no_grad():
            weight = last.weight.reshape(channels, -1) / source.temperature
            self.mask.weight.copy_((center @ weight).reshape_as(self.mask.weight))
            self.mask.bias.copy_(center @ (last.bias / source.temperature))
        self.register_buffer("group_sum", same.reshape(channels, channels, 1, 1))
        # Neighbour k of the 3x3 window, repeated for every subpixel channel.
        eye = torch.eye(9).reshape(9, 1, 3, 3)
        self.register_buffer("neighbours", eye.repeat_interleave(sub, dim=0))
        self.register_buffer("subpixel_sum", torch.eye(sub).repeat(1, 9).reshape(sub, channels, 1, 1))

    def forward(self, features, depth):
        # Explicit edge copies avoid backend-specific replicate-pad lowering.
        padded = torch.cat((depth[:, :, :1, :], depth, depth[:, :, -1:, :]), dim=2)
        padded = torch.cat((padded[:, :, :, :1], padded, padded[:, :, :, -1:]), dim=3)
        neighbours = F.conv2d(padded, self.neighbours)
        weights = torch.exp(torch.clamp(self.mask(self.features(features)), max=self.CLAMP))
        weights = weights / F.conv2d(weights, self.group_sum)
        pixels = F.conv2d(weights * neighbours, self.subpixel_sum)
        return F.pixel_shuffle(F.relu(pixels), self.scale)


def weighted_context(self, features):
    batch, _, height, width = features.shape
    weights = F.softmax(self.context_weight(features).reshape(batch, 1, 1, height * width), dim=3)
    weighted = features * weights.reshape(batch, 1, height, width)
    context = weighted.sum(dim=3, keepdim=True).sum(dim=2, keepdim=True)
    return features + self.transform(context)


def dense(conv):
    """Grouped 1x1 convolution as an equivalent dense one (block-diagonal weights, exact zeros).

    MNN OpenCL splits each group into its own convolution plus slice/concat copies; on Quest 3 at
    384x224 these copies were most of the graph's Raster time. The dense form costs groups-times
    the multiply-adds of these small projections but runs as one kernel.
    """
    out_group, in_group = conv.out_channels // conv.groups, conv.in_channels // conv.groups
    result = nn.Conv2d(conv.in_channels, conv.out_channels, 1, bias=conv.bias is not None)
    with torch.no_grad():
        result.weight.zero_()
        for group in range(conv.groups):
            result.weight[group * out_group:(group + 1) * out_group, group * in_group:(group + 1) * in_group] = \
                conv.weight[group * out_group:(group + 1) * out_group]
        if conv.bias is not None:
            result.bias.copy_(conv.bias)
    return result


def adapt(model):
    head = model.decoder.convex_up
    if not head.use_unfold:
        raise ValueError("Expected the base checkpoint's learned convex head")
    model.decoder.convex_up = ConvexUpsample2D(head)
    for parent in list(model.modules()):
        for name, child in list(parent.named_children()):
            if (isinstance(child, nn.Conv2d) and child.kernel_size == (1, 1) and child.stride == (1, 1)
                    and 1 < child.groups < child.in_channels):
                setattr(parent, name, dense(child))
    for module in model.modules():
        if type(module).__name__ == "GlobalContextBlock":
            module.forward = types.MethodType(weighted_context, module)
    return model.eval()
