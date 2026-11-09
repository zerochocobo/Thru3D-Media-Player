#include "mnn_rvm_graph.h"
#include "MNN_generated.h"
#include <stdexcept>
#include <string>

namespace quest {
std::vector<uint8_t> rvm_portable_graph(const void* model, size_t bytes) {
    flatbuffers::Verifier verifier(static_cast<const uint8_t*>(model), bytes);
    if (!MNN::VerifyNetBuffer(verifier)) throw std::runtime_error("Invalid RVM graph buffer");
    auto graph = MNN::UnPackNet(model);
    if (!graph || !graph->subgraphs.empty()) throw std::runtime_error("Unsupported RVM graph structure");
    std::vector<std::unique_ptr<MNN::OpT>> ops;
    size_t restored = 0;
    for (auto& op : graph->oplists) {
        const auto marker = op->name.find("__hswish");
        if (marker == std::string::npos) { ops.emplace_back(std::move(op)); continue; }
        if ((op->type != MNN::OpType_Convolution && op->type != MNN::OpType_ConvolutionDepthwise) ||
            op->outputIndexes.size() != 1 || !op->main.AsConvolution2D() ||
            !op->main.AsConvolution2D()->common || op->main.AsConvolution2D()->common->relu ||
            op->main.AsConvolution2D()->common->relu6)
            throw std::runtime_error("Unsupported fused RVM activation");
        const int output = op->outputIndexes[0];
        if (output < 0 || static_cast<size_t>(output) >= graph->tensorName.size())
            throw std::runtime_error("Invalid fused RVM tensor");
        const int intermediate = static_cast<int>(graph->tensorName.size());
        graph->tensorName.push_back(graph->tensorName[output] + "__vulkan_pre_hswish");
        op->outputIndexes[0] = intermediate;
        op->name.erase(marker, std::string("__hswish").size());
        auto activation = std::make_unique<MNN::OpT>();
        activation->type = MNN::OpType_UnaryOp;
        activation->name = op->name + "_portable_hswish";
        activation->defaultDimentionFormat = op->defaultDimentionFormat;
        activation->inputIndexes = {intermediate};
        activation->outputIndexes = {output};
        MNN::UnaryOpT unary;
        unary.opType = MNN::UnaryOpOperation_HARDSWISH;
        unary.T = MNN::DataType_DT_FLOAT;
        activation->main.Set(std::move(unary));
        ops.emplace_back(std::move(op));
        ops.emplace_back(std::move(activation));
        ++restored;
    }
    if (restored == 0) throw std::runtime_error("RVM graph lacks the expected fused activations");
    graph->oplists = std::move(ops);
    graph->tensorNumber = static_cast<int>(graph->tensorName.size());
    flatbuffers::FlatBufferBuilder builder;
    MNN::FinishNetBuffer(builder, MNN::Net::Pack(builder, graph.get()));
    return {builder.GetBufferPointer(), builder.GetBufferPointer() + builder.GetSize()};
}
}
