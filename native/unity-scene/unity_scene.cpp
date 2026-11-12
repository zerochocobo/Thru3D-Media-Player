// Unity scene AssetBundle -> neutral scene container. Every length, offset and count read
// from the file is checked before use: the input is an arbitrary user download.
#include "unity_scene.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

struct Failure : std::runtime_error { using std::runtime_error::runtime_error; };
[[noreturn]] void fail(const std::string& reason) { throw Failure(reason); }

constexpr uint64_t kMaxUncompressed = 3ull << 30;   // decompressed bundle
constexpr size_t kMaxValues = 4000000;              // parsed type-tree values per object
constexpr int kMaxDepth = 48;
constexpr uint32_t kMaxObjects = 2000000;
constexpr uint32_t kMaxVertices = 16000000;

const char kCommonStrings[] =
#include "common_strings.inc"
    ;

struct Span {
    const uint8_t* data = nullptr;
    size_t size = 0;
};

class In {
public:
    In() = default;
    In(const uint8_t* data, size_t size, bool big = false) : data_(data), size_(size), big_(big) {}
    size_t pos() const { return pos_; }
    size_t size() const { return size_; }
    size_t left() const { return size_ - pos_; }
    void big(bool value) { big_ = value; }
    void seek(uint64_t pos) { if (pos > size_) fail("offset outside file"); pos_ = size_t(pos); }
    void align(size_t to) { size_t rest = pos_ % to; if (rest) seek(uint64_t(pos_) + to - rest); }
    const uint8_t* take(uint64_t count) {
        if (count > left()) fail("data ends early");
        const uint8_t* at = data_ + pos_;
        pos_ += size_t(count);
        return at;
    }
    uint8_t u8() { return *take(1); }
    uint16_t u16() { const uint8_t* p = take(2); return big_ ? uint16_t(p[0] << 8 | p[1]) : uint16_t(p[1] << 8 | p[0]); }
    uint32_t u32() {
        const uint8_t* p = take(4);
        return big_ ? uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]
                    : uint32_t(p[3]) << 24 | uint32_t(p[2]) << 16 | uint32_t(p[1]) << 8 | p[0];
    }
    uint64_t u64() {
        uint64_t a = u32(), b = u32();
        return big_ ? a << 32 | b : b << 32 | a;
    }
    int32_t i32() { return int32_t(u32()); }
    int64_t i64() { return int64_t(u64()); }
    std::string text() {
        size_t start = pos_;
        while (pos_ < size_ && data_[pos_]) pos_++;
        if (pos_ >= size_) fail("unterminated string");
        std::string value(reinterpret_cast<const char*>(data_ + start), pos_ - start);
        pos_++;
        return value;
    }
private:
    const uint8_t* data_ = nullptr;
    size_t size_ = 0, pos_ = 0;
    bool big_ = false;
};

// ---------------------------------------------------------------- LZ4 block
void lz4_block(const uint8_t* in, size_t in_size, uint8_t* out, size_t out_size) {
    size_t ip = 0, op = 0;
    while (ip < in_size) {
        uint8_t token = in[ip++];
        size_t literal = token >> 4;
        if (literal == 15) {
            uint8_t more;
            do { if (ip >= in_size) fail("corrupt LZ4 block"); more = in[ip++]; literal += more; } while (more == 255);
        }
        if (literal > in_size - ip || literal > out_size - op) fail("corrupt LZ4 block");
        std::memcpy(out + op, in + ip, literal);
        ip += literal; op += literal;
        if (ip >= in_size) break;
        if (in_size - ip < 2) fail("corrupt LZ4 block");
        size_t offset = in[ip] | size_t(in[ip + 1]) << 8;
        ip += 2;
        size_t match = token & 15;
        if (match == 15) {
            uint8_t more;
            do { if (ip >= in_size) fail("corrupt LZ4 block"); more = in[ip++]; match += more; } while (more == 255);
        }
        match += 4;
        if (offset == 0 || offset > op || match > out_size - op) fail("corrupt LZ4 block");
        const uint8_t* from = out + op - offset;
        if (offset >= match) std::memcpy(out + op, from, match);
        else for (size_t i = 0; i < match; i++) out[op + i] = from[i];
        op += match;
    }
    if (op != out_size) fail("corrupt LZ4 block");
}

// ---------------------------------------------------------------- LZMA
// Raw LZMA stream as Unity stores it: 5 property bytes, then the range-coded data.
// Follows the public-domain reference decoder in the LZMA specification.
class Lzma {
public:
    Lzma(const uint8_t* in, size_t in_size, uint8_t* out, size_t out_size) : in_(in), in_size_(in_size), out_(out), out_size_(out_size) {}

    void run() {
        if (in_size_ < 5 + 5) fail("corrupt LZMA block");
        unsigned d = in_[0];
        if (d >= 9 * 5 * 5) fail("corrupt LZMA block");
        lc_ = d % 9; d /= 9; pb_ = d / 5; lp_ = d % 5;
        at_ = 5;
        if (next() != 0) fail("corrupt LZMA block");
        for (int i = 0; i < 4; i++) code_ = code_ << 8 | next();
        literal_.assign(size_t(0x300) << (lc_ + lp_), 1024);
        uint32_t rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0;
        unsigned state = 0;
        size_t op = 0;
        while (op < out_size_) {
            unsigned pos_state = unsigned(op) & ((1u << pb_) - 1);
            if (bit(is_match_[(state << 4) + pos_state]) == 0) {
                unsigned previous = op ? out_[op - 1] : 0;
                uint16_t* probs = &literal_[size_t(0x300) * (((unsigned(op) & ((1u << lp_) - 1)) << lc_) + (previous >> (8 - lc_)))];
                unsigned symbol = 1;
                if (state >= 7) {
                    if (rep0 >= op) fail("corrupt LZMA block");
                    unsigned match_byte = out_[op - rep0 - 1];
                    do {
                        unsigned match_bit = (match_byte >> 7) & 1;
                        match_byte <<= 1;
                        unsigned b = bit(probs[((1 + match_bit) << 8) + symbol]);
                        symbol = symbol << 1 | b;
                        if (match_bit != b) break;
                    } while (symbol < 0x100);
                }
                while (symbol < 0x100) symbol = symbol << 1 | bit(probs[symbol]);
                out_[op++] = uint8_t(symbol);
                state = state < 4 ? 0 : state < 10 ? state - 3 : state - 6;
                continue;
            }
            size_t length;
            if (bit(is_rep_[state])) {
                if (op == 0) fail("corrupt LZMA block");
                if (bit(is_rep_g0_[state]) == 0) {
                    if (bit(is_rep0_long_[(state << 4) + pos_state]) == 0) {
                        if (rep0 >= op) fail("corrupt LZMA block");
                        out_[op] = out_[op - rep0 - 1];
                        op++;
                        state = state < 7 ? 9 : 11;
                        continue;
                    }
                } else {
                    uint32_t distance;
                    if (bit(is_rep_g1_[state]) == 0) distance = rep1;
                    else {
                        if (bit(is_rep_g2_[state]) == 0) distance = rep2;
                        else { distance = rep3; rep3 = rep2; }
                        rep2 = rep1;
                    }
                    rep1 = rep0;
                    rep0 = distance;
                }
                length = rep_length_.decode(*this, pos_state);
                state = state < 7 ? 8 : 11;
            } else {
                rep3 = rep2; rep2 = rep1; rep1 = rep0;
                length = length_.decode(*this, pos_state);
                state = state < 7 ? 7 : 10;
                unsigned slot = tree(slot_[length < 3 ? length : 3], 6);
                if (slot < 4) rep0 = slot;
                else {
                    unsigned direct = (slot >> 1) - 1;
                    rep0 = (2 | (slot & 1)) << direct;
                    if (slot < 14) rep0 += reverse(&position_[rep0 - slot], direct);
                    else {
                        uint32_t high = 0;
                        for (unsigned i = direct - 4; i > 0; i--) {
                            range_ >>= 1;
                            code_ -= range_;
                            uint32_t t = 0 - (code_ >> 31);
                            code_ += range_ & t;
                            normalize();
                            high = (high << 1) + t + 1;
                        }
                        rep0 += high << 4;
                        rep0 += reverse(align_, 4);
                    }
                }
                if (rep0 == 0xffffffffu) break;
            }
            length += 2;
            if (rep0 >= op || length > out_size_ - op) fail("corrupt LZMA block");
            const uint8_t* from = out_ + op - rep0 - 1;
            for (size_t i = 0; i < length; i++) out_[op + i] = from[i];
            op += length;
        }
        if (op != out_size_) fail("corrupt LZMA block");
    }

private:
    struct Length {
        uint16_t choice = 1024, choice2 = 1024, low[16][8], mid[16][8], high[256];
        Length() {
            for (auto& row : low) for (uint16_t& p : row) p = 1024;
            for (auto& row : mid) for (uint16_t& p : row) p = 1024;
            for (uint16_t& p : high) p = 1024;
        }
        size_t decode(Lzma& coder, unsigned pos_state) {
            if (coder.bit(choice) == 0) return coder.tree(low[pos_state], 3);
            if (coder.bit(choice2) == 0) return 8 + coder.tree(mid[pos_state], 3);
            return 16 + coder.tree(high, 8);
        }
    };

    uint8_t next() { if (at_ >= in_size_) fail("corrupt LZMA block"); return in_[at_++]; }
    void normalize() { if (range_ < (1u << 24)) { range_ <<= 8; code_ = code_ << 8 | next(); } }
    unsigned bit(uint16_t& prob) {
        uint32_t bound = (range_ >> 11) * prob;
        unsigned symbol;
        if (code_ < bound) { prob = uint16_t(prob + ((2048 - prob) >> 5)); range_ = bound; symbol = 0; }
        else { prob = uint16_t(prob - (prob >> 5)); code_ -= bound; range_ -= bound; symbol = 1; }
        normalize();
        return symbol;
    }
    unsigned tree(uint16_t* probs, unsigned bits) {
        unsigned m = 1;
        for (unsigned i = 0; i < bits; i++) m = (m << 1) + bit(probs[m]);
        return m - (1u << bits);
    }
    unsigned reverse(uint16_t* probs, unsigned bits) {
        unsigned m = 1, symbol = 0;
        for (unsigned i = 0; i < bits; i++) { unsigned b = bit(probs[m]); m = (m << 1) + b; symbol |= b << i; }
        return symbol;
    }
    template <size_t N> struct Probs {
        uint16_t p[N];
        Probs() { for (uint16_t& value : p) value = 1024; }
        operator uint16_t*() { return p; }
    };

    const uint8_t* in_;
    size_t in_size_, at_ = 0;
    uint8_t* out_;
    size_t out_size_;
    unsigned lc_ = 0, lp_ = 0, pb_ = 0;
    uint32_t range_ = 0xffffffffu, code_ = 0;
    std::vector<uint16_t> literal_;
    Probs<12 << 4> is_match_, is_rep0_long_;
    Probs<12> is_rep_, is_rep_g0_, is_rep_g1_, is_rep_g2_;
    Probs<64> slot_[4];
    Probs<16> align_;
    Probs<1 + 128 - 14> position_;
    Length length_, rep_length_;
};

// ---------------------------------------------------------------- bundle
struct BundleNode { std::string path; uint64_t offset = 0, size = 0; };

struct Bundle {
    std::string unity_version;
    std::vector<uint8_t> data;
    std::vector<BundleNode> nodes;
};

std::string base_name(const std::string& path) {
    size_t slash = path.find_last_of("/\\");
    std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    return name;
}

Bundle read_bundle(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) fail("bundle cannot be opened");
    file.seekg(0, std::ios::end);
    uint64_t file_size = uint64_t(file.tellg());
    auto read_at = [&](uint64_t offset, uint64_t count) {
        if (offset > file_size || count > file_size - offset) fail("bundle is truncated");
        std::vector<uint8_t> bytes(static_cast<size_t>(count));
        file.seekg(std::streamoff(offset));
        file.read(reinterpret_cast<char*>(bytes.data()), std::streamsize(count));
        if (!file) fail("bundle cannot be read");
        return bytes;
    };
    std::vector<uint8_t> head = read_at(0, std::min<uint64_t>(file_size, 512));
    In in(head.data(), head.size(), true);
    if (in.text() != "UnityFS") fail("not a Unity asset bundle");
    uint32_t format = in.u32();
    if (format < 6 || format > 8) fail("unsupported bundle format");
    Bundle bundle;
    bundle.unity_version = in.text();
    in.text();
    in.i64();
    uint32_t packed_info = in.u32(), info_size = in.u32(), flags = in.u32();
    if (format >= 7) in.align(16);
    if (info_size > (64u << 20) || packed_info > (64u << 20)) fail("bundle directory too large");
    uint64_t info_at = flags & 0x80 ? file_size - packed_info : in.pos();
    uint64_t data_at = flags & 0x80 ? in.pos() : in.pos() + packed_info;
    if (flags & 0x200) data_at = (data_at + 15) & ~uint64_t(15);
    auto unpack = [](uint32_t kind, const std::vector<uint8_t>& packed, uint8_t* out, size_t out_size) {
        if ((kind & 0x3f) == 0) {
            if (packed.size() != out_size) fail("corrupt bundle block");
            std::memcpy(out, packed.data(), out_size);
        } else if ((kind & 0x3f) == 2 || (kind & 0x3f) == 3) lz4_block(packed.data(), packed.size(), out, out_size);
        else if ((kind & 0x3f) == 1) { auto coder = std::make_unique<Lzma>(packed.data(), packed.size(), out, out_size); coder->run(); }
        else fail("unsupported bundle compression");
    };
    std::vector<uint8_t> info(info_size);
    unpack(flags, read_at(info_at, packed_info), info.data(), info.size());
    In dir(info.data(), info.size(), true);
    dir.take(16);
    uint32_t block_count = dir.u32();
    if (block_count > dir.left() / 10) fail("corrupt bundle directory");
    struct Block { uint32_t size, packed; uint16_t flags; };
    std::vector<Block> blocks(block_count);
    uint64_t total = 0;
    for (Block& block : blocks) {
        block.size = dir.u32(); block.packed = dir.u32(); block.flags = dir.u16();
        if (block.flags & 0x100) fail("encrypted bundles are not supported");
        total += block.size;
    }
    if (total > kMaxUncompressed) fail("bundle is too large");
    uint32_t node_count = dir.u32();
    if (node_count > dir.left() / 21) fail("corrupt bundle directory");
    for (uint32_t i = 0; i < node_count; i++) {
        BundleNode node;
        node.offset = dir.u64(); node.size = dir.u64(); dir.u32(); node.path = dir.text();
        if (node.offset > total || node.size > total - node.offset) fail("corrupt bundle directory");
        bundle.nodes.push_back(std::move(node));
    }
    bundle.data.resize(static_cast<size_t>(total));
    uint64_t in_at = data_at, out_at = 0;
    for (const Block& block : blocks) {
        unpack(block.flags, read_at(in_at, block.packed), bundle.data.data() + out_at, block.size);
        in_at += block.packed; out_at += block.size;
    }
    return bundle;
}

// ---------------------------------------------------------------- type trees
struct Primitive { const char* name; uint8_t size; char kind; };  // kind: i signed, u unsigned, f float, b bool
const Primitive kPrimitives[] = {
    {"SInt8", 1, 'i'}, {"UInt8", 1, 'u'}, {"char", 1, 'u'}, {"bool", 1, 'b'},
    {"short", 2, 'i'}, {"SInt16", 2, 'i'}, {"UInt16", 2, 'u'}, {"unsigned short", 2, 'u'},
    {"int", 4, 'i'}, {"SInt32", 4, 'i'}, {"UInt32", 4, 'u'}, {"unsigned int", 4, 'u'}, {"Type*", 4, 'u'},
    {"long long", 8, 'i'}, {"SInt64", 8, 'i'}, {"UInt64", 8, 'u'}, {"unsigned long long", 8, 'u'}, {"FileSize", 8, 'u'},
    {"float", 4, 'f'}, {"double", 8, 'f'},
};

struct TypeNode {
    std::string type, name;
    int level = 0;
    bool align = false;
    const Primitive* primitive = nullptr;
    std::vector<int> children;
};

struct TypeInfo {
    int class_id = 0;
    int script_index = -1;
    std::vector<TypeNode> nodes;
};

struct Value {
    enum Kind { Null, Int, Float, Text, Raw, Array, Object } kind = Null;
    int64_t integer = 0;
    double number = 0;
    std::string text;
    Span raw;                           // packed primitive array or typeless data
    const Primitive* element = nullptr; // element type of a Raw array
    std::vector<Value> items;
    std::vector<std::pair<const TypeNode*, Value>> fields;
    const TypeNode* node = nullptr;

    const Value& operator[](const char* name) const {
        static const Value none;
        for (const auto& field : fields) if (field.first->name == name) return field.second;
        return none;
    }
    bool has(const char* name) const { return (*this)[name].kind != Null; }
    double num(double fallback = 0) const { return kind == Float ? number : kind == Int ? double(integer) : fallback; }
    int64_t whole(int64_t fallback = 0) const { return kind == Int ? integer : kind == Float ? int64_t(number) : fallback; }
    size_t count() const { return kind == Array ? items.size() : kind == Raw && element ? raw.size / element->size : 0; }
};

double raw_number(const Value& value, size_t index) {
    const Primitive* p = value.element;
    if (!p || index >= value.raw.size / p->size) return 0;
    const uint8_t* at = value.raw.data + index * p->size;
    if (p->kind == 'f') {
        if (p->size == 4) { float v; std::memcpy(&v, at, 4); return v; }
        double v; std::memcpy(&v, at, 8); return v;
    }
    uint64_t bits = 0;
    std::memcpy(&bits, at, p->size);
    if (p->kind == 'i') {
        int shift = 64 - 8 * p->size;
        return double(int64_t(bits << shift) >> shift);
    }
    return double(bits);
}

struct ValueReader {
    In& in;
    const TypeInfo& type;
    size_t budget = kMaxValues;

    Value read(int index, int depth) {
        if (depth > kMaxDepth) fail("type tree too deep");
        if (budget == 0) fail("object too large");
        budget--;
        const TypeNode& node = type.nodes[size_t(index)];
        Value value;
        value.node = &node;
        if (node.primitive) {
            const Primitive* p = node.primitive;
            const uint8_t* at = in.take(p->size);
            uint64_t bits = 0;
            std::memcpy(&bits, at, p->size);
            if (p->kind == 'f') {
                value.kind = Value::Float;
                if (p->size == 4) { float v; std::memcpy(&v, at, 4); value.number = v; }
                else std::memcpy(&value.number, at, 8);
            } else {
                value.kind = Value::Int;
                int shift = 64 - 8 * p->size;
                value.integer = p->kind == 'i' ? int64_t(bits << shift) >> shift : int64_t(bits);
            }
        } else if (node.type == "string") {
            uint32_t length = in.u32();
            const uint8_t* at = in.take(length);
            value.kind = Value::Text;
            value.text.assign(reinterpret_cast<const char*>(at), length);
            in.align(4);
        } else if (node.type == "TypelessData") {
            uint32_t length = in.u32();
            value.kind = Value::Raw;
            value.raw = {in.take(length), length};
            value.element = &kPrimitives[1];
        } else if (node.type == "ManagedReferencesRegistry") {
            fail("managed references are not supported");
        } else if (node.children.size() == 1 && type.nodes[size_t(node.children[0])].type == "Array") {
            const TypeNode& array = type.nodes[size_t(node.children[0])];
            value = read_array(array, depth);
            value.node = &node;
            if (array.align) in.align(4);
        } else if (node.type == "Array") {
            value = read_array(node, depth);
        } else {
            value.kind = Value::Object;
            value.fields.reserve(node.children.size());
            for (int child : node.children) value.fields.emplace_back(&type.nodes[size_t(child)], read(child, depth + 1));
        }
        if (node.align) in.align(4);
        return value;
    }

    Value read_array(const TypeNode& array, int depth) {
        if (array.children.size() != 2) fail("malformed array type");
        uint32_t count = in.u32();
        const TypeNode& element = type.nodes[size_t(array.children[1])];
        Value value;
        value.node = &array;
        if (element.primitive) {
            value.kind = Value::Raw;
            value.element = element.primitive;
            value.raw = {in.take(uint64_t(count) * element.primitive->size), size_t(count) * element.primitive->size};
        } else {
            if (count > in.left()) fail("array longer than its data");
            value.kind = Value::Array;
            value.items.reserve(std::min<uint32_t>(count, 4096));
            for (uint32_t i = 0; i < count; i++) value.items.push_back(read(array.children[1], depth + 1));
        }
        return value;
    }
};

// ---------------------------------------------------------------- serialized files
struct ObjectEntry { uint64_t start = 0; uint32_t size = 0; int type = -1; };

struct Serialized {
    std::string name;
    Span data;
    std::vector<TypeInfo> types;
    std::unordered_map<int64_t, ObjectEntry> objects;
    std::vector<int64_t> order;
    std::vector<std::string> externals;
    std::vector<int> external_files;
    std::string unity_version;
    int platform = 0;
};

std::vector<TypeNode> read_type_tree(In& in, uint32_t version) {
    uint32_t node_count = in.u32(), text_size = in.u32();
    size_t node_bytes = version >= 19 ? 32 : 24;
    if (node_count == 0 || node_count > in.left() / node_bytes) fail("corrupt type tree");
    In rows(in.take(uint64_t(node_count) * node_bytes), size_t(node_count) * node_bytes);
    const uint8_t* text = in.take(text_size);
    auto lookup = [&](uint32_t offset) -> std::string {
        const char* base = reinterpret_cast<const char*>(text);
        size_t limit = text_size;
        if (offset & 0x80000000u) { base = kCommonStrings; limit = sizeof(kCommonStrings); offset &= 0x7fffffffu; }
        if (offset >= limit) fail("corrupt type tree");
        size_t length = 0;
        while (offset + length < limit && base[offset + length]) length++;
        return std::string(base + offset, length);
    };
    std::vector<TypeNode> nodes(node_count);
    std::vector<int> stack;
    for (uint32_t i = 0; i < node_count; i++) {
        rows.u16();
        int level = rows.u8();
        rows.u8();
        uint32_t type_at = rows.u32(), name_at = rows.u32();
        rows.i32(); rows.i32();
        uint32_t meta = rows.u32();
        if (version >= 19) rows.u64();
        TypeNode& node = nodes[i];
        node.type = lookup(type_at);
        node.name = lookup(name_at);
        node.level = level;
        node.align = (meta & 0x4000) != 0;
        if (level > kMaxDepth || (i == 0) != (level == 0) || size_t(level) > stack.size()) fail("corrupt type tree");
        stack.resize(size_t(level));
        if (level > 0) nodes[size_t(stack.back())].children.push_back(int(i));
        stack.push_back(int(i));
    }
    for (TypeNode& node : nodes) {
        if (!node.children.empty()) continue;
        for (const Primitive& p : kPrimitives) if (node.type == p.name) node.primitive = &p;
    }
    return nodes;
}

Serialized read_serialized(const std::string& name, Span data) {
    Serialized file;
    file.name = base_name(name);
    file.data = data;
    In in(data.data, data.size, true);
    in.u32(); in.u32();
    uint32_t version = in.u32();
    uint64_t data_offset = in.u32();
    if (version < 17 || version > 22) fail("unsupported Unity serialization version " + std::to_string(version));
    bool big = in.u8() != 0;
    in.take(3);
    if (version >= 22) { in.u32(); in.i64(); data_offset = in.u64(); in.i64(); }
    if (big) fail("big-endian bundles are not supported");
    in.big(false);
    file.unity_version = in.text();
    file.platform = in.i32();
    bool has_trees = in.u8() != 0;
    if (!has_trees) fail("bundle carries no type information");
    auto read_types = [&](bool reference) {
        uint32_t count = in.u32();
        if (count > in.left() / 20) fail("corrupt type table");
        std::vector<TypeInfo> types(count);
        for (TypeInfo& type : types) {
            type.class_id = in.i32();
            in.u8();
            type.script_index = int16_t(in.u16());
            if ((reference && type.script_index >= 0) || type.class_id == 114) in.take(16);
            in.take(16);
            type.nodes = read_type_tree(in, version);
            if (version >= 21) {
                if (reference) { in.text(); in.text(); in.text(); }
                else { uint32_t deps = in.u32(); in.take(uint64_t(deps) * 4); }
            }
        }
        return types;
    };
    file.types = read_types(false);
    uint32_t object_count = in.u32();
    if (object_count > kMaxObjects || object_count > in.left() / 20) fail("corrupt object table");
    for (uint32_t i = 0; i < object_count; i++) {
        in.align(4);
        int64_t path_id = in.i64();
        ObjectEntry entry;
        entry.start = (version >= 22 ? in.u64() : in.u32()) + data_offset;
        entry.size = in.u32();
        entry.type = in.i32();
        if (entry.type < 0 || size_t(entry.type) >= file.types.size()) fail("corrupt object table");
        if (entry.start > data.size || entry.size > data.size - entry.start) fail("object outside file");
        if (file.objects.emplace(path_id, entry).second) file.order.push_back(path_id);
    }
    uint32_t script_count = in.u32();
    for (uint32_t i = 0; i < script_count; i++) { in.i32(); in.align(4); in.i64(); }
    uint32_t external_count = in.u32();
    if (external_count > in.left() / 22) fail("corrupt external table");
    for (uint32_t i = 0; i < external_count; i++) {
        in.text(); in.take(16); in.i32();
        file.externals.push_back(base_name(in.text()));
    }
    return file;
}

// ---------------------------------------------------------------- output
struct Json {
    enum Kind { Null, Bool, Number, Text, List, Dict } kind = Null;
    bool flag = false;
    double number = 0;
    std::string text;
    std::vector<Json> list;
    std::vector<std::pair<std::string, Json>> dict;

    Json() = default;
    Json(bool value) : kind(Bool), flag(value) {}
    Json(double value) : kind(Number), number(value) {}
    Json(int value) : kind(Number), number(value) {}
    Json(int64_t value) : kind(Number), number(double(value)) {}
    Json(uint64_t value) : kind(Number), number(double(value)) {}
    Json(uint32_t value) : kind(Number), number(value) {}
    Json(const std::string& value) : kind(Text), text(value) {}
    Json(const char* value) : kind(Text), text(value) {}
    static Json array() { Json j; j.kind = List; return j; }
    static Json object() { Json j; j.kind = Dict; return j; }
    Json& add(Json value) { list.push_back(std::move(value)); return *this; }
    Json& set(const std::string& key, Json value) { dict.emplace_back(key, std::move(value)); return *this; }

    static void quote(const std::string& value, std::string& out) {
        out += '"';
        for (unsigned char c : value) {
            if (c == '"' || c == '\\') { out += '\\'; out += char(c); }
            else if (c < 0x20) { char buffer[8]; std::snprintf(buffer, sizeof buffer, "\\u%04x", c); out += buffer; }
            else out += char(c);
        }
        out += '"';
    }
    void write(std::string& out) const {
        switch (kind) {
        case Null: out += "null"; break;
        case Bool: out += flag ? "true" : "false"; break;
        case Number: {
            if (!std::isfinite(number)) { out += "0"; break; }
            char buffer[40];
            if (number == std::floor(number) && std::fabs(number) < 9e15) std::snprintf(buffer, sizeof buffer, "%lld", static_cast<long long>(number));
            else std::snprintf(buffer, sizeof buffer, "%.9g", number);
            out += buffer;
            break;
        }
        case Text: quote(text, out); break;
        case List:
            out += '[';
            for (size_t i = 0; i < list.size(); i++) { if (i) out += ','; list[i].write(out); }
            out += ']';
            break;
        case Dict:
            out += '{';
            for (size_t i = 0; i < dict.size(); i++) { if (i) out += ','; quote(dict[i].first, out); out += ':'; dict[i].second.write(out); }
            out += '}';
            break;
        }
    }
};

// Keeps only well-formed UTF-8 so the JSON stays parseable whatever a name contains.
std::string clean_text(const std::string& value, size_t limit = 256) {
    std::string out;
    for (size_t i = 0; i < value.size() && out.size() < limit;) {
        unsigned char c = static_cast<unsigned char>(value[i]);
        size_t length = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
        bool ok = length > 0 && i + length <= value.size();
        for (size_t k = 1; ok && k < length; k++) ok = (static_cast<unsigned char>(value[i + k]) >> 6) == 2;
        if (ok) out.append(value, i, length); else out += '?';
        i += ok ? length : 1;
    }
    return out;
}

class Output {
public:
    explicit Output(const std::filesystem::path& path) : file_(path, std::ios::binary | std::ios::trunc) {
        if (!file_) fail("output cannot be created");
        char header[24] = {};
        file_.write(header, sizeof header);
        at_ = sizeof header;
    }
    Json blob(const void* data, size_t size) {
        file_.write(static_cast<const char*>(data), std::streamsize(size));
        Json where = Json::object();
        where.set("offset", at_).set("size", uint64_t(size));
        at_ += size;
        return where;
    }
    void finish(const Json& scene) {
        std::string text;
        scene.write(text);
        uint64_t json_at = at_, json_size = text.size();
        file_.write(text.data(), std::streamsize(text.size()));
        file_.seekp(0);
        file_.write("T3DSCENE", 8);
        file_.write(reinterpret_cast<const char*>(&json_at), 8);   // little-endian hosts only (x86-64, arm64)
        file_.write(reinterpret_cast<const char*>(&json_size), 8);
        file_.flush();
        if (!file_) fail("output cannot be written");
    }
private:
    std::ofstream file_;
    uint64_t at_ = 0;
};

// ---------------------------------------------------------------- math
struct Affine { double m[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1}; double t[3] = {0, 0, 0}; };  // row-major 3x3 + origin

Affine multiply(const Affine& a, const Affine& b) {
    Affine r;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) r.m[i * 3 + j] = a.m[i * 3] * b.m[j] + a.m[i * 3 + 1] * b.m[3 + j] + a.m[i * 3 + 2] * b.m[6 + j];
        r.t[i] = a.m[i * 3] * b.t[0] + a.m[i * 3 + 1] * b.t[1] + a.m[i * 3 + 2] * b.t[2] + a.t[i];
    }
    return r;
}

Affine from_trs(const Value& transform) {
    const Value& q = transform["m_LocalRotation"];
    const Value& p = transform["m_LocalPosition"];
    const Value& s = transform["m_LocalScale"];
    double x = q["x"].num(), y = q["y"].num(), z = q["z"].num(), w = q["w"].num(1);
    double norm = std::sqrt(x * x + y * y + z * z + w * w);
    if (norm > 1e-9) { x /= norm; y /= norm; z /= norm; w /= norm; } else { x = y = z = 0; w = 1; }
    double scale[3] = {s["x"].num(1), s["y"].num(1), s["z"].num(1)};
    double r[9] = {1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
                   2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
                   2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)};
    Affine a;
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) a.m[i * 3 + j] = r[i * 3 + j] * scale[j];
    a.t[0] = p["x"].num(); a.t[1] = p["y"].num(); a.t[2] = p["z"].num();
    return a;
}

// Unity is left-handed with +Z forward; the output mirrors Z so forward becomes Godot's -Z.
// Emitted as basis columns then origin, the order Transform3D takes them.
Json to_json(const Affine& a) {
    Json list = Json::array();
    for (int column = 0; column < 3; column++)
        for (int row = 0; row < 3; row++)
            list.add(a.m[row * 3 + column] * ((row == 2) != (column == 2) ? -1.0 : 1.0));
    list.add(a.t[0]).add(a.t[1]).add(-a.t[2]);
    return list;
}

float half_to_float(uint16_t h) {
    uint32_t sign = uint32_t(h & 0x8000) << 16, exponent = (h >> 10) & 31, mantissa = h & 1023, bits;
    if (exponent == 0) {
        if (mantissa == 0) bits = sign;
        else {
            int shift = 0;
            while (!(mantissa & 1024)) { mantissa <<= 1; shift++; }
            bits = sign | uint32_t(113 - shift) << 23 | (mantissa & 1023) << 13;
        }
    } else if (exponent == 31) bits = sign | 0x7f800000u | mantissa << 13;
    else bits = sign | (exponent + 112) << 23 | mantissa << 13;
    float value;
    std::memcpy(&value, &bits, 4);
    return value;
}

// ---------------------------------------------------------------- scene extraction
struct Ref {
    int file = -1;
    int64_t path = 0;
    bool operator<(const Ref& other) const { return file != other.file ? file < other.file : path < other.path; }
    bool valid() const { return file >= 0 && path != 0; }
};

struct Channel { const uint8_t* data = nullptr; size_t stride = 0; int format = 0, dimension = 0; };

const int kFormatBytes[12] = {4, 2, 1, 1, 2, 2, 1, 1, 2, 2, 4, 4};

float component(const Channel& channel, size_t vertex, int index) {
    if (index >= channel.dimension) return 0;
    const uint8_t* at = channel.data + vertex * channel.stride + size_t(index) * size_t(kFormatBytes[channel.format]);
    switch (channel.format) {
    case 0: { float v; std::memcpy(&v, at, 4); return v; }
    case 1: { uint16_t v; std::memcpy(&v, at, 2); return half_to_float(v); }
    case 2: case 6: return at[0] / 255.0f;
    case 3: case 7: return std::max(int8_t(at[0]) / 127.0f, -1.0f);
    case 4: case 8: { uint16_t v; std::memcpy(&v, at, 2); return v / 65535.0f; }
    case 5: case 9: { int16_t v; std::memcpy(&v, at, 2); return std::max(v / 32767.0f, -1.0f); }
    default: return 0;
    }
}

struct TextureFormat { int unity; const char* name; int block; int block_bytes; int pixel_bytes; };
const TextureFormat kTextureFormats[] = {
    {1, "l8", 0, 0, 1}, {3, "rgb8", 0, 0, 3}, {4, "rgba8", 0, 0, 4}, {5, "argb8", 0, 0, 4}, {14, "bgra8", 0, 0, 4},
    {63, "r8", 0, 0, 1}, {17, "rgbah", 0, 0, 8}, {20, "rgbaf", 0, 0, 16},
    {10, "dxt1", 4, 8, 0}, {12, "dxt5", 4, 16, 0}, {24, "bptc_rgbfu", 4, 16, 0}, {25, "bptc_rgba", 4, 16, 0},
    {26, "rgtc_r", 4, 8, 0}, {27, "rgtc_rg", 4, 16, 0},
    {34, "etc", 4, 8, 0}, {45, "etc2_rgb8", 4, 8, 0}, {46, "etc2_rgb8a1", 4, 8, 0}, {47, "etc2_rgba8", 4, 16, 0},
    {41, "etc2_r11", 4, 8, 0}, {43, "etc2_rg11", 4, 16, 0},
    {48, "astc_4x4", 4, 16, 0}, {54, "astc_4x4", 4, 16, 0}, {51, "astc_8x8", 8, 16, 0}, {57, "astc_8x8", 8, 16, 0},
};

class Scene {
public:
    Scene(Bundle& bundle, Output& output, int max_texture, int max_sky) : bundle_(bundle), out_(output), max_texture_(max_texture), max_sky_(max_sky) {}

    Json build() {
        for (const BundleNode& node : bundle_.nodes) {
            Span span{bundle_.data.data() + node.offset, static_cast<size_t>(node.size)};
            resources_[base_name(node.path)] = span;
            std::string lower = base_name(node.path);
            auto ends = [&](const char* suffix) { size_t n = std::strlen(suffix); return lower.size() >= n && lower.compare(lower.size() - n, n, suffix) == 0; };
            if (ends(".ress") || ends(".resource")) continue;
            try { files_.push_back(read_serialized(node.path, span)); }
            catch (const Failure& failure) { warn(clean_text(node.path) + ": " + failure.what()); }
        }
        if (files_.empty()) fail(warnings_.empty() ? "bundle holds no scene data" : warnings_.back());
        for (Serialized& file : files_)
            for (const std::string& external : file.externals) {
                int found = -1;
                for (size_t i = 0; i < files_.size(); i++) if (files_[i].name == external) found = int(i);
                file.external_files.push_back(found);
            }
        Json renderers = Json::array(), colliders = Json::array(), behaviours = Json::array(), lights = Json::array();
        Json scene = Json::object();
        for (size_t f = 0; f < files_.size(); f++) {
            for (int64_t path : files_[f].order) {
                Ref ref{int(f), path};
                try {
                    switch (class_of(ref)) {
                    case 23: renderer(ref, renderers); break;
                    case 64: collider(ref, colliders); break;
                    case 114: behaviour(ref, behaviours); break;
                    case 108: light(ref, lights); break;
                    case 104: settings(ref, scene); break;
                    default: break;
                    }
                } catch (const Failure& failure) {
                    warn("object skipped: " + std::string(failure.what()));
                }
            }
        }
        scene.set("format", 1);
        scene.set("unity_version", clean_text(files_[0].unity_version));
        scene.set("platform", files_[0].platform);
        scene.set("textures", std::move(textures_));
        scene.set("materials", std::move(materials_));
        scene.set("surfaces", std::move(surfaces_));
        scene.set("renderers", std::move(renderers));
        scene.set("colliders", std::move(colliders));
        scene.set("behaviours", std::move(behaviours));
        scene.set("lights", std::move(lights));
        Json lightmaps = Json::array();
        for (int index : lightmap_textures_) lightmaps.add(index);
        scene.set("lightmaps", std::move(lightmaps));
        Json notes = Json::array();
        for (const std::string& note : warnings_) notes.add(note);
        scene.set("warnings", std::move(notes));
        return scene;
    }

private:
    Bundle& bundle_;
    Output& out_;
    int max_texture_, max_sky_;
    std::vector<Serialized> files_;
    std::map<std::string, Span> resources_;
    std::map<Ref, std::shared_ptr<Value>> parsed_;
    std::map<Ref, int> texture_index_, material_index_, object_index_;
    std::map<Ref, Affine> world_;
    std::map<std::string, int> surface_index_;
    std::vector<int> lightmap_textures_;
    bool lightmaps_read_ = false;
    Json textures_ = Json::array(), materials_ = Json::array(), surfaces_ = Json::array();
    std::vector<std::string> warnings_;

    void warn(const std::string& note) { if (warnings_.size() < 64) warnings_.push_back(note); }

    int class_of(Ref ref) {
        if (ref.file < 0) return 0;
        const Serialized& file = files_[size_t(ref.file)];
        auto found = file.objects.find(ref.path);
        return found == file.objects.end() ? 0 : file.types[size_t(found->second.type)].class_id;
    }

    const Value& parse(Ref ref, bool keep = true) {
        static const Value none;
        if (ref.file < 0) return none;
        auto cached = parsed_.find(ref);
        if (cached != parsed_.end()) return *cached->second;
        const Serialized& file = files_[size_t(ref.file)];
        auto found = file.objects.find(ref.path);
        if (found == file.objects.end()) return none;
        const TypeInfo& type = file.types[size_t(found->second.type)];
        if (type.nodes.empty()) return none;
        In in(file.data.data + found->second.start, found->second.size);
        ValueReader reader{in, type};
        auto value = std::make_shared<Value>(reader.read(0, 0));
        if (!keep) { scratch_ = value; return *scratch_; }
        return *(parsed_[ref] = value);
    }
    std::shared_ptr<Value> scratch_;

    Ref pointer(const Value& value, int from_file) {
        int64_t file_id = value["m_FileID"].whole(), path = value["m_PathID"].whole();
        if (path == 0) return {};
        if (file_id == 0) return {from_file, path};
        const Serialized& file = files_[size_t(from_file)];
        if (file_id < 0 || size_t(file_id) > file.external_files.size()) return {};
        return {file.external_files[size_t(file_id - 1)], path};
    }

    int object_id(Ref game_object) {
        auto found = object_index_.find(game_object);
        if (found != object_index_.end()) return found->second;
        int id = int(object_index_.size());
        return object_index_[game_object] = id;
    }

    Ref component_of(Ref game_object, int class_id) {
        const Value& components = parse(game_object)["m_Component"];
        for (const Value& item : components.items) {
            Ref ref = pointer(item["component"], game_object.file);
            if (class_of(ref) == class_id) return ref;
        }
        return {};
    }

    bool active(Ref game_object) {
        Ref current = game_object;
        for (int depth = 0; depth < 256 && current.valid(); depth++) {
            const Value& object = parse(current);
            if (object.kind != Value::Object || object["m_IsActive"].whole(1) == 0) return false;
            Ref transform = component_of(current, 4);
            if (!transform.valid()) transform = component_of(current, 224);
            if (!transform.valid()) return true;
            Ref parent = pointer(parse(transform)["m_Father"], transform.file);
            if (!parent.valid()) return true;
            current = pointer(parse(parent)["m_GameObject"], parent.file);
        }
        return true;
    }

    Affine world(Ref transform) {
        std::vector<Ref> chain;
        Ref current = transform;
        while (current.valid() && chain.size() < 256) {
            auto known = world_.find(current);
            if (known != world_.end()) break;
            if (class_of(current) != 4 && class_of(current) != 224) break;
            chain.push_back(current);
            current = pointer(parse(current)["m_Father"], current.file);
        }
        Affine result;
        auto known = world_.find(current);
        if (current.valid() && known != world_.end()) result = known->second;
        for (size_t i = chain.size(); i-- > 0;) {
            result = multiply(result, from_trs(parse(chain[i])));
            world_[chain[i]] = result;
        }
        return result;
    }

    Affine world_of(Ref game_object) {
        Ref transform = component_of(game_object, 4);
        if (!transform.valid()) transform = component_of(game_object, 224);
        return transform.valid() ? world(transform) : Affine();
    }

    std::string name_of(Ref game_object) { return clean_text(parse(game_object)["m_Name"].text); }

    Span stream(const Value& info) {
        uint64_t size = uint64_t(info["size"].whole());
        if (size == 0) return {};
        auto found = resources_.find(base_name(info["path"].text));
        if (found == resources_.end()) fail("external data file missing from bundle");
        uint64_t offset = uint64_t(info["offset"].whole());
        if (offset > found->second.size || size > found->second.size - offset) fail("external data outside file");
        return {found->second.data + offset, static_cast<size_t>(size)};
    }

    int unity_major(int file) { return std::atoi(files_[size_t(file)].unity_version.c_str()); }

    // -------- meshes
    struct MeshView {
        uint32_t vertices = 0;
        Channel position, normal, color, uv, uv2;
        Span indices;
        bool wide = false;
    };

    MeshView view(Ref mesh_ref) {
        const Value& mesh = parse(mesh_ref);
        if (mesh.kind != Value::Object) fail("mesh missing");
        if (mesh["m_CompressedMesh"]["m_Vertices"]["m_NumItems"].whole() > 0) fail("compressed meshes are not supported yet");
        const Value& data = mesh["m_VertexData"];
        MeshView out;
        int64_t count = data["m_VertexCount"].whole();
        if (count <= 0 || count > kMaxVertices) fail("mesh has no usable vertices");
        out.vertices = uint32_t(count);
        Span bytes = data["m_DataSize"].raw;
        if (bytes.size == 0) bytes = stream(mesh["m_StreamData"]);
        const Value& channels = data["m_Channels"];
        int major = unity_major(mesh_ref.file);
        size_t channel_count = channels.items.size();
        struct Layout { int stream, offset, format, dimension; };
        std::vector<Layout> layouts;
        size_t stream_count = 0;
        for (const Value& item : channels.items) {
            Layout layout{int(item["stream"].whole()), int(item["offset"].whole()), int(item["format"].whole()), int(item["dimension"].whole()) & 15};
            if (major < 2017) { const int legacy[5] = {0, 1, 2, 6, 10}; layout.format = layout.format >= 0 && layout.format < 5 ? legacy[layout.format] : -1; }
            else if (major < 2019) { const int legacy[13] = {0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}; layout.format = layout.format >= 0 && layout.format < 13 ? legacy[layout.format] : -1; }
            if (layout.format < 0 || layout.format > 11 || layout.stream < 0 || layout.stream > 7 || layout.offset < 0 || layout.dimension > 4) layout.dimension = 0;
            if (layout.dimension > 0) stream_count = std::max(stream_count, size_t(layout.stream) + 1);
            layouts.push_back(layout);
        }
        std::vector<size_t> stride(stream_count, 0), start(stream_count, 0);
        for (const Layout& layout : layouts)
            if (layout.dimension > 0) stride[size_t(layout.stream)] = std::max(stride[size_t(layout.stream)], size_t(layout.offset) + size_t(kFormatBytes[layout.format]) * size_t(layout.dimension));
        size_t at = 0;
        for (size_t s = 0; s < stream_count; s++) {
            stride[s] = (stride[s] + 3) & ~size_t(3);
            start[s] = at;
            at += size_t(out.vertices) * stride[s];
            if (at > bytes.size) fail("vertex data shorter than its layout");
            at = (at + 15) & ~size_t(15);
        }
        auto channel = [&](size_t index) {
            Channel c;
            if (index >= channel_count || layouts[index].dimension == 0) return c;
            const Layout& layout = layouts[index];
            c.data = bytes.data + start[size_t(layout.stream)] + size_t(layout.offset);
            c.stride = stride[size_t(layout.stream)];
            c.format = layout.format;
            c.dimension = layout.dimension;
            return c;
        };
        bool modern = major >= 2018;
        out.position = channel(0);
        out.normal = channel(1);
        out.color = channel(modern ? 3 : 2);
        out.uv = channel(modern ? 4 : 3);
        out.uv2 = channel(modern ? 5 : 4);
        if (out.position.dimension < 3) fail("mesh has no positions");
        out.indices = mesh["m_IndexBuffer"].raw;
        out.wide = mesh["m_IndexFormat"].whole(0) == 1;
        return out;
    }

    // One drawable piece: a sub-mesh with its own compact vertex range. `st` bakes the
    // renderer's lightmap placement into UV2 so no per-instance shader data is needed.
    int surface(Ref mesh_ref, size_t submesh, const double* st, bool geometry_only) {
        char key[160];
        std::snprintf(key, sizeof key, "%d:%lld:%zu:%d:%.9g:%.9g:%.9g:%.9g", mesh_ref.file, static_cast<long long>(mesh_ref.path), submesh,
                      geometry_only ? 1 : 0, st ? st[0] : 1, st ? st[1] : 1, st ? st[2] : 0, st ? st[3] : 0);
        auto known = surface_index_.find(key);
        if (known != surface_index_.end()) return known->second;
        int result = -1;
        const Value& mesh = parse(mesh_ref);
        const Value& submeshes = mesh["m_SubMeshes"];
        try {
            if (submesh >= submeshes.items.size()) fail("sub-mesh missing");
            const Value& part = submeshes.items[submesh];
            if (part["topology"].whole() != 0) fail("only triangle meshes are supported");
            MeshView mesh_view = view(mesh_ref);
            uint64_t first_byte = uint64_t(part["firstByte"].whole()), index_count = uint64_t(part["indexCount"].whole());
            size_t index_bytes = mesh_view.wide ? 4 : 2;
            if (index_count == 0 || index_count % 3 || first_byte > mesh_view.indices.size || index_count > (mesh_view.indices.size - first_byte) / index_bytes)
                fail("sub-mesh indices outside the mesh");
            int64_t base = part["baseVertex"].whole();
            std::vector<uint32_t> indices(static_cast<size_t>(index_count));
            uint32_t low = UINT32_MAX, high = 0;
            for (size_t i = 0; i < indices.size(); i++) {
                const uint8_t* at = mesh_view.indices.data + first_byte + i * index_bytes;
                uint32_t raw = 0;
                std::memcpy(&raw, at, index_bytes);
                int64_t index = int64_t(raw) + base;
                if (index < 0 || index >= mesh_view.vertices) fail("index outside the mesh");
                indices[i] = uint32_t(index);
                low = std::min(low, indices[i]); high = std::max(high, indices[i]);
            }
            size_t count = size_t(high - low) + 1;
            // Mirrored geometry needs the opposite winding.
            for (size_t i = 0; i < indices.size(); i += 3) { indices[i] -= low; uint32_t b = indices[i + 1] - low; indices[i + 1] = indices[i + 2] - low; indices[i + 2] = b; }
            std::vector<float> buffer(count * 3);
            float lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
            for (size_t v = 0; v < count; v++)
                for (int c = 0; c < 3; c++) {
                    float value = component(mesh_view.position, low + v, c) * (c == 2 ? -1.0f : 1.0f);
                    if (!std::isfinite(value)) value = 0;
                    buffer[v * 3 + size_t(c)] = value;
                    lo[c] = std::min(lo[c], value); hi[c] = std::max(hi[c], value);
                }
            Json entry = Json::object();
            entry.set("vertices", uint64_t(count)).set("triangles", uint64_t(indices.size() / 3));
            entry.set("name", clean_text(mesh["m_Name"].text));
            Json bounds = Json::array();
            for (float value : lo) bounds.add(double(value));
            for (float value : hi) bounds.add(double(value));
            entry.set("bounds", std::move(bounds));
            entry.set("position", out_.blob(buffer.data(), buffer.size() * 4));
            entry.set("index", out_.blob(indices.data(), indices.size() * 4));
            if (!geometry_only) {
                if (mesh_view.normal.dimension >= 3) {
                    for (size_t v = 0; v < count; v++)
                        for (int c = 0; c < 3; c++) buffer[v * 3 + size_t(c)] = component(mesh_view.normal, low + v, c) * (c == 2 ? -1.0f : 1.0f);
                    entry.set("normal", out_.blob(buffer.data(), buffer.size() * 4));
                }
                buffer.resize(count * 2);
                if (mesh_view.uv.dimension >= 2) {
                    for (size_t v = 0; v < count; v++) for (int c = 0; c < 2; c++) buffer[v * 2 + size_t(c)] = component(mesh_view.uv, low + v, c);
                    entry.set("uv", out_.blob(buffer.data(), buffer.size() * 4));
                }
                const Channel& second = mesh_view.uv2.dimension >= 2 ? mesh_view.uv2 : mesh_view.uv;
                if (st && second.dimension >= 2) {
                    for (size_t v = 0; v < count; v++)
                        for (int c = 0; c < 2; c++) buffer[v * 2 + size_t(c)] = float(component(second, low + v, c) * st[c] + st[2 + c]);
                    entry.set("uv2", out_.blob(buffer.data(), buffer.size() * 4));
                }
                if (mesh_view.color.dimension >= 3) {
                    buffer.resize(count * 4);
                    for (size_t v = 0; v < count; v++)
                        for (int c = 0; c < 4; c++) buffer[v * 4 + size_t(c)] = c < mesh_view.color.dimension ? component(mesh_view.color, low + v, c) : 1.0f;
                    entry.set("color", out_.blob(buffer.data(), buffer.size() * 4));
                }
            }
            result = int(surfaces_.list.size());
            surfaces_.add(std::move(entry));
        } catch (const Failure& failure) {
            warn(clean_text(mesh["m_Name"].text) + ": " + failure.what());
        }
        return surface_index_[key] = result;
    }

    // -------- textures and materials
    int texture(Ref ref) {
        if (!ref.valid() || class_of(ref) != 28) return -1;
        auto known = texture_index_.find(ref);
        if (known != texture_index_.end()) return known->second;
        int result = -1;
        try {
            const Value& value = parse(ref, false);
            std::string name = clean_text(value["m_Name"].text);
            int64_t width = value["m_Width"].whole(), height = value["m_Height"].whole(), mips = std::max<int64_t>(value["m_MipCount"].whole(1), 1);
            int unity_format = int(value["m_TextureFormat"].whole());
            const TextureFormat* format = nullptr;
            for (const TextureFormat& candidate : kTextureFormats) if (candidate.unity == unity_format) format = &candidate;
            if (!format) fail("texture format " + std::to_string(unity_format) + " is not supported");
            if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || mips > 15) fail("texture has unusable dimensions");
            if (value["m_ImageCount"].whole(1) != 1) fail("texture arrays are not supported");
            Span data = value["image data"].raw;
            if (data.size == 0) data = stream(value["m_StreamData"]);
            auto level_bytes = [&](int64_t w, int64_t h) -> size_t {
                if (format->block) return size_t((w + format->block - 1) / format->block) * size_t((h + format->block - 1) / format->block) * size_t(format->block_bytes);
                return size_t(w) * size_t(h) * size_t(format->pixel_bytes);
            };
            size_t offset = 0;
            int64_t w = width, h = height, kept = mips;
            while (kept > 1 && max_texture_ > 0 && std::max(w, h) > max_texture_) {
                offset += level_bytes(w, h);
                w = std::max<int64_t>(w / 2, 1); h = std::max<int64_t>(h / 2, 1); kept--;
            }
            size_t total = 0;
            int64_t lw = w, lh = h, usable = 0;
            for (int64_t level = 0; level < kept; level++) {
                size_t bytes = level_bytes(lw, lh);
                if (offset + total + bytes > data.size) break;
                total += bytes; usable++;
                lw = std::max<int64_t>(lw / 2, 1); lh = std::max<int64_t>(lh / 2, 1);
            }
            if (usable == 0) fail("texture data shorter than its header");
            // The engine wants either one level or a full chain down to 1x1.
            bool full_chain = usable > 1 && lw == 1 && lh == 1 && (std::max(w, h) >> (usable - 1)) == 1;
            if (!full_chain) { usable = 1; total = level_bytes(w, h); }
            std::string name_out = format->name;
            std::vector<uint8_t> swizzled;
            const uint8_t* pixels = data.data + offset;
            if (name_out == "argb8" || name_out == "bgra8") {
                swizzled.assign(pixels, pixels + total);
                for (size_t i = 0; i + 3 < swizzled.size(); i += 4) {
                    if (name_out == "argb8") { uint8_t a = swizzled[i]; swizzled[i] = swizzled[i + 1]; swizzled[i + 1] = swizzled[i + 2]; swizzled[i + 2] = swizzled[i + 3]; swizzled[i + 3] = a; }
                    else std::swap(swizzled[i], swizzled[i + 2]);
                }
                pixels = swizzled.data();
                name_out = "rgba8";
            }
            Json entry = Json::object();
            entry.set("name", name).set("width", w).set("height", h).set("format", name_out).set("mipmaps", usable > 1);
            entry.set("srgb", value["m_ColorSpace"].whole(1) == 1);
            entry.set("lightmap_format", value["m_LightmapFormat"].whole());
            entry.set("repeat", value["m_TextureSettings"]["m_WrapU"].whole(value["m_TextureSettings"]["m_WrapMode"].whole()) == 0);
            entry.set("data", out_.blob(pixels, total));
            result = int(textures_.list.size());
            textures_.add(std::move(entry));
        } catch (const Failure& failure) {
            warn(std::string("texture skipped: ") + failure.what());
        }
        scratch_.reset();
        return texture_index_[ref] = result;
    }

    std::string shader_name(Ref ref) {
        if (class_of(ref) != 48) return "";
        const Value& shader = parse(ref, false);
        std::string name = shader["m_ParsedForm"]["m_Name"].text;
        if (name.empty()) name = shader["m_Name"].text;
        scratch_.reset();
        return clean_text(name);
    }

    int material(Ref ref) {
        if (!ref.valid() || class_of(ref) != 21) return -1;
        auto known = material_index_.find(ref);
        if (known != material_index_.end()) return known->second;
        const Value& value = parse(ref);
        Json entry = Json::object();
        entry.set("name", clean_text(value["m_Name"].text));
        entry.set("shader", shader_name(pointer(value["m_Shader"], ref.file)));
        entry.set("render_queue", value["m_CustomRenderQueue"].whole(-1));
        Json keywords = Json::array();
        for (const Value& keyword : value["m_ValidKeywords"].items) keywords.add(clean_text(keyword.text));
        std::string joined = value["m_ShaderKeywords"].text;
        for (size_t at = 0; at < joined.size();) {
            size_t end = joined.find(' ', at);
            if (end == std::string::npos) end = joined.size();
            if (end > at) keywords.add(clean_text(joined.substr(at, end - at)));
            at = end + 1;
        }
        entry.set("keywords", std::move(keywords));
        Json tags = Json::object();
        for (const Value& tag : value["stringTagMap"].items) tags.set(clean_text(tag["first"].text), clean_text(tag["second"].text));
        entry.set("tags", std::move(tags));
        const Value& saved = value["m_SavedProperties"];
        Json floats = Json::object(), colors = Json::object(), maps = Json::object();
        for (const Value& item : saved["m_Floats"].items) floats.set(clean_text(item["first"].text), item["second"].num());
        for (const Value& item : saved["m_Ints"].items) floats.set(clean_text(item["first"].text), item["second"].num());
        for (const Value& item : saved["m_Colors"].items) {
            const Value& c = item["second"];
            Json color = Json::array();
            color.add(c["r"].num()).add(c["g"].num()).add(c["b"].num()).add(c["a"].num(1));
            colors.set(clean_text(item["first"].text), std::move(color));
        }
        for (const Value& item : saved["m_TexEnvs"].items) {
            const Value& env = item["second"];
            int index = texture(pointer(env["m_Texture"], ref.file));
            if (index < 0) continue;
            Json map = Json::object();
            map.set("texture", index);
            Json scale = Json::array(), offset = Json::array();
            scale.add(env["m_Scale"]["x"].num(1)).add(env["m_Scale"]["y"].num(1));
            offset.add(env["m_Offset"]["x"].num()).add(env["m_Offset"]["y"].num());
            map.set("scale", std::move(scale)).set("offset", std::move(offset));
            maps.set(clean_text(item["first"].text), std::move(map));
        }
        entry.set("floats", std::move(floats)).set("colors", std::move(colors)).set("textures", std::move(maps));
        int index = int(materials_.list.size());
        materials_.add(std::move(entry));
        return material_index_[ref] = index;
    }

    void read_lightmaps() {
        if (lightmaps_read_) return;
        lightmaps_read_ = true;
        for (size_t f = 0; f < files_.size(); f++)
            for (int64_t path : files_[f].order) {
                Ref ref{int(f), path};
                if (class_of(ref) != 157) continue;
                const Value& settings = parse(ref);
                for (const Value& item : settings["m_Lightmaps"].items)
                    lightmap_textures_.push_back(texture(pointer(item["m_Lightmap"], ref.file)));
                return;
            }
    }

    // -------- components
    void renderer(Ref ref, Json& renderers) {
        const Value& value = parse(ref);
        Ref owner = pointer(value["m_GameObject"], ref.file);
        if (value["m_Enabled"].whole(1) == 0 || !owner.valid() || !active(owner)) return;
        Ref filter = component_of(owner, 33);
        if (!filter.valid()) return;
        Ref mesh_ref = pointer(parse(filter)["m_Mesh"], filter.file);
        if (class_of(mesh_ref) != 43) return;
        const Value& mesh = parse(mesh_ref);
        size_t submesh_count = mesh["m_SubMeshes"].items.size();
        const Value& batch = value["m_StaticBatchInfo"];
        size_t first = 0, count = submesh_count;
        bool batched = batch["subMeshCount"].whole() > 0;
        if (batched) { first = size_t(batch["firstSubMesh"].whole()); count = size_t(batch["subMeshCount"].whole()); }
        if (first > submesh_count || count > submesh_count - first) return;
        read_lightmaps();
        int64_t lightmap = value["m_LightmapIndex"].whole(0xffff);
        bool lit = lightmap >= 0 && size_t(lightmap) < lightmap_textures_.size() && lightmap_textures_[size_t(lightmap)] >= 0;
        const Value& placement = value["m_LightmapTilingOffset"];
        // Static batching has already moved UV2 into the atlas; other meshes still need the placement.
        double st[4] = {1, 1, 0, 0};
        if (!batched) { st[0] = placement["x"].num(1); st[1] = placement["y"].num(1); st[2] = placement["z"].num(); st[3] = placement["w"].num(); }
        Json parts = Json::array();
        const Value& materials = value["m_Materials"];
        for (size_t i = 0; i < count && i < materials.items.size(); i++) {
            int index = surface(mesh_ref, first + i, lit ? st : nullptr, false);
            if (index < 0) continue;
            Json part = Json::object();
            part.set("surface", index).set("material", material(pointer(materials.items[i], ref.file)));
            parts.add(std::move(part));
        }
        if (parts.list.empty()) return;
        Json entry = Json::object();
        entry.set("name", name_of(owner)).set("object", object_id(owner));
        entry.set("transform", to_json(batched ? Affine() : world_of(owner)));
        entry.set("lightmap", lit ? lightmap_textures_[size_t(lightmap)] : -1);
        entry.set("surfaces", std::move(parts));
        renderers.add(std::move(entry));
    }

    void collider(Ref ref, Json& colliders) {
        const Value& value = parse(ref);
        Ref owner = pointer(value["m_GameObject"], ref.file);
        if (value["m_Enabled"].whole(1) == 0 || !owner.valid() || !active(owner)) return;
        Json entry = Json::object();
        entry.set("name", name_of(owner)).set("object", object_id(owner)).set("transform", to_json(world_of(owner)));
        // Geometry is written on demand by `behaviour` for the objects scripts point at.
        Ref mesh_ref = pointer(value["m_Mesh"], ref.file);
        if (class_of(mesh_ref) == 43) collider_mesh_[owner] = mesh_ref;
        colliders.add(std::move(entry));
    }
    std::map<Ref, Ref> collider_mesh_;

    Json field(const Value& value, int file, int depth) {
        switch (value.kind) {
        case Value::Int: return Json(value.integer);
        case Value::Float: return Json(value.number);
        case Value::Text: return Json(clean_text(value.text));
        case Value::Raw: {
            Json list = Json::array();
            for (size_t i = 0; i < value.count() && i < 32; i++) list.add(raw_number(value, i));
            return list;
        }
        case Value::Array: {
            Json list = Json::array();
            if (depth < 5) for (size_t i = 0; i < value.items.size() && i < 32; i++) list.add(field(value.items[i], file, depth + 1));
            return list;
        }
        case Value::Object: {
            if (value.node && value.node->type.compare(0, 5, "PPtr<") == 0) {
                Ref target = pointer(value, file);
                int kind = class_of(target);
                if (kind != 1 && kind != 0) {
                    const Value& component = parse(target, kind != 114 && kind != 43 && kind != 28);
                    Ref owner = pointer(component["m_GameObject"], target.file);
                    scratch_.reset();
                    target = owner;
                    kind = class_of(target);
                }
                if (kind != 1) return Json();
                Json node = Json::object();
                node.set("name", name_of(target)).set("object", object_id(target)).set("transform", to_json(world_of(target)));
                return node;
            }
            Json dict = Json::object();
            if (depth < 5) for (const auto& item : value.fields) dict.set(item.first->name, field(item.second, file, depth + 1));
            return dict;
        }
        default: return Json();
        }
    }

    void behaviour(Ref ref, Json& behaviours) {
        if (behaviours.list.size() >= 4096) return;
        auto value = std::make_shared<Value>(parse(ref, false));
        scratch_.reset();
        Ref owner = pointer((*value)["m_GameObject"], ref.file);
        if (!owner.valid() || !active(owner) || (*value)["m_Enabled"].whole(1) == 0) return;
        Ref script = pointer((*value)["m_Script"], ref.file);
        std::string class_name = class_of(script) == 115 ? clean_text(parse(script)["m_ClassName"].text) : "";
        if (class_name.empty()) return;
        Json entry = Json::object();
        entry.set("class", class_name).set("name", name_of(owner)).set("object", object_id(owner)).set("transform", to_json(world_of(owner)));
        Json fields = Json::object();
        for (const auto& item : value->fields) {
            const std::string& name = item.first->name;
            if (name == "m_GameObject" || name == "m_Enabled" || name == "m_Script" || name == "m_Name" || name == "m_EditorHideFlags" || name == "m_EditorClassIdentifier") continue;
            fields.set(name, field(item.second, ref.file, 0));
        }
        entry.set("fields", std::move(fields));
        // Walkable or interactive areas are often collider-only; keep their shape.
        auto shape = collider_mesh_.find(owner);
        if (shape == collider_mesh_.end()) {
            Ref collider_ref = component_of(owner, 64);
            if (collider_ref.valid()) {
                Ref mesh_ref = pointer(parse(collider_ref)["m_Mesh"], collider_ref.file);
                if (class_of(mesh_ref) == 43) shape = collider_mesh_.emplace(owner, mesh_ref).first;
            }
        }
        // The visible mesh doubles as the floor when the collider uses the same one.
        Ref filter = component_of(owner, 33);
        bool drawn = shape != collider_mesh_.end() && filter.valid() && component_of(owner, 23).valid()
            && pointer(parse(filter)["m_Mesh"], filter.file).path == shape->second.path
            && pointer(parse(filter)["m_Mesh"], filter.file).file == shape->second.file;
        if (shape != collider_mesh_.end() && !drawn) {
            Json parts = Json::array();
            size_t count = parse(shape->second)["m_SubMeshes"].items.size();
            for (size_t i = 0; i < count; i++) {
                int index = surface(shape->second, i, nullptr, true);
                if (index >= 0) parts.add(index);
            }
            entry.set("collider_surfaces", std::move(parts));
        }
        behaviours.add(std::move(entry));
    }

    void light(Ref ref, Json& lights) {
        const Value& value = parse(ref);
        Ref owner = pointer(value["m_GameObject"], ref.file);
        if (value["m_Enabled"].whole(1) == 0 || !owner.valid() || !active(owner)) return;
        const Value& c = value["m_Color"];
        Json color = Json::array();
        color.add(c["r"].num(1)).add(c["g"].num(1)).add(c["b"].num(1));
        Json entry = Json::object();
        entry.set("name", name_of(owner)).set("type", value["m_Type"].whole()).set("color", std::move(color));
        entry.set("intensity", value["m_Intensity"].num(1)).set("range", value["m_Range"].num(10));
        entry.set("baked", value["m_BakingOutput"]["lightmapBakeMode"]["lightmapBakeType"].whole() == 2);
        entry.set("transform", to_json(world_of(owner)));
        lights.add(std::move(entry));
    }

    void settings(Ref ref, Json& scene) {
        const Value& value = parse(ref);
        auto color = [](const Value& c) { Json list = Json::array(); list.add(c["r"].num()).add(c["g"].num()).add(c["b"].num()); return list; };
        scene.set("ambient", color(value["m_AmbientSkyColor"]));
        scene.set("ambient_mode", value["m_AmbientMode"].whole());
        scene.set("ambient_intensity", value["m_AmbientIntensity"].num(1));
        // A panorama wraps the whole view, so it gets its own, larger size limit.
        std::swap(max_texture_, max_sky_);
        scene.set("sky_material", material(pointer(value["m_SkyboxMaterial"], ref.file)));
        std::swap(max_texture_, max_sky_);
        scene.set("fog", value["m_Fog"].whole() != 0);
        scene.set("fog_color", color(value["m_FogColor"]));
        scene.set("fog_density", value["m_FogDensity"].num());
    }
};

}  // namespace

int thru3d_unity_scene_unpack(const char* bundle_path, const char* output_path, int max_texture, int max_sky_texture, char* error, size_t error_size) {
    auto report = [&](const char* reason) {
        if (error && error_size) std::snprintf(error, error_size, "%s", reason);
        return 1;
    };
    if (!bundle_path || !output_path) return report("missing path");
    std::filesystem::path target = std::filesystem::u8path(output_path);
    try {
        Bundle bundle = read_bundle(std::filesystem::u8path(bundle_path));
        {
            Output output(target);
            Scene scene(bundle, output, max_texture, max_sky_texture);
            output.finish(scene.build());
        }
        if (error && error_size) error[0] = 0;
        return 0;
    } catch (const std::bad_alloc&) {
        std::error_code ignored;
        std::filesystem::remove(target, ignored);
        return report("not enough memory for this bundle");
    } catch (const std::exception& failure) {
        std::error_code ignored;
        std::filesystem::remove(target, ignored);
        return report(failure.what());
    }
}
