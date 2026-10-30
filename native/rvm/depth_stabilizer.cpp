#include "depth_stabilizer.h"

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstring>

namespace quest {
namespace {
// Inputs to motion estimation are bounded grayscale. Explicit complex arithmetic
// avoids libc++'s exceptional-value complex multiply path in every FFT butterfly.
struct cf {
    float r = 0, i = 0;
    cf() = default;
    cf(float real, float imag = 0) : r(real), i(imag) {}
    cf operator+(cf b) const { return {r + b.r, i + b.i}; }
    cf operator-(cf b) const { return {r - b.r, i - b.i}; }
    cf operator*(cf b) const { return {r * b.r - i * b.i, r * b.i + i * b.r}; }
    cf operator/(float b) const { return {r / b, i / b}; }
};
constexpr float kPi = 3.14159265358979f;
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point since) { return std::chrono::duration<double, std::milli>(Clock::now() - since).count(); }

float rate(float a, int k) {
    // Source-frame gaps are integers. The common 1..8 cases need no per-pixel powf.
    const float b = 1.f - a, b2 = b * b, b4 = b2 * b2;
    switch (k) {
        case 1: return a;
        case 2: return 1.f - b2;
        case 3: return 1.f - b2 * b;
        case 4: return 1.f - b4;
        case 5: return 1.f - b4 * b;
        case 6: return 1.f - b4 * b2;
        case 7: return 1.f - b4 * b2 * b;
        case 8: return 1.f - b4 * b4;
        default: return 1.f - std::pow(b, static_cast<float>(std::max(1, k)));
    }
}

int pow2(int n) { int p = 1; while (p < n) p <<= 1; return p; }

struct FftPlan {
    int n = 0;
    std::vector<int> reverse;
    std::vector<cf> roots;
    void prepare(int size) {
        if (n == size) return;
        n = size; reverse.resize(n); roots.resize(n);
        reverse[0] = 0;
        for (int i = 1, j = 0; i < n; ++i) {
            int bit = n >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit; reverse[i] = j;
        }
        for (int len = 2; len <= n; len <<= 1) {
            const float angle = -2 * kPi / len;
            const cf step(std::cos(angle), std::sin(angle));
            cf root(1.f);
            for (int k = 0; k < len / 2; ++k) { roots[len / 2 + k] = root; root = root * step; }
        }
    }
    void run(cf* data, bool inverse) const {
        for (int i = 1; i < n; ++i) if (i < reverse[i]) std::swap(data[i], data[reverse[i]]);
        for (int len = 2; len <= n; len <<= 1) {
            for (int i = 0; i < n; i += len) for (int k = 0; k < len / 2; ++k) {
                cf root = roots[len / 2 + k];
                if (inverse) root.i = -root.i;
                cf& a = data[i + k];
                cf& b = data[i + k + len / 2];
                const cf t = b * root;
                b = a - t; a = a + t;
            }
        }
    }
};

struct PhaseWorkspace {
    int w = 0, h = 0, pw = 0, ph = 0;
    FftPlan rows, columns;
    std::vector<float> window;
    std::vector<float> previous_input;
    std::vector<cf> a, b, transposed;
    void prepare(int width, int height) {
        if (w == width && h == height) return;
        w = width; h = height; pw = pow2(w); ph = pow2(h);
        previous_input.clear();
        rows.prepare(pw); columns.prepare(ph);
        a.resize(size_t(pw) * ph); b.resize(a.size()); transposed.resize(a.size());
        window.resize(size_t(w) * h);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x)
            window[y * w + x] = (0.5f * (1 - std::cos(2 * kPi * x / float(w - 1)))) *
                                (0.5f * (1 - std::cos(2 * kPi * y / float(h - 1))));
    }
    void fft2(std::vector<cf>& data, bool inverse) {
        for (int y = 0; y < ph; ++y) rows.run(data.data() + y * pw, inverse);
        // Keep the column FFT contiguous, instead of repeatedly traversing a large stride.
        for (int by = 0; by < ph; by += 16) for (int bx = 0; bx < pw; bx += 16)
            for (int y = by; y < std::min(by + 16, ph); ++y) for (int x = bx; x < std::min(bx + 16, pw); ++x)
                transposed[x * ph + y] = data[y * pw + x];
        for (int x = 0; x < pw; ++x) columns.run(transposed.data() + x * ph, inverse);
        for (int by = 0; by < ph; by += 16) for (int bx = 0; bx < pw; bx += 16)
            for (int y = by; y < std::min(by + 16, ph); ++y) for (int x = bx; x < std::min(bx + 16, pw); ++x)
                data[y * pw + x] = transposed[x * ph + y];
    }
};

// Separable box blur, size k (odd), replicate border (cv2.blur).
void box(const std::vector<float>& src, std::vector<float>& tmp, std::vector<float>& dst, int w, int h, int k) {
    const int r = k / 2;
    for (int y = 0; y < h; ++y) {
        double acc = 0;
        for (int d = -r; d <= r; ++d) acc += src[y * w + std::clamp(d, 0, w - 1)];
        for (int x = 0; x < w; ++x) {
            tmp[y * w + x] = static_cast<float>(acc / k);
            acc += double(src[y * w + std::min(x + r + 1, w - 1)]) - src[y * w + std::max(x - r, 0)];
        }
    }
    std::vector<double> columns(w, 0.0);
    for (int d = -r; d <= r; ++d) for (int x = 0; x < w; ++x) columns[x] += tmp[std::clamp(d, 0, h - 1) * w + x];
    for (int y = 0; y < h; ++y) {
        const float* add = tmp.data() + std::min(y + r + 1, h - 1) * w;
        const float* sub = tmp.data() + std::max(y - r, 0) * w;
        for (int x = 0; x < w; ++x) {
            dst[y * w + x] = static_cast<float>(columns[x] / k);
            columns[x] += double(add[x]) - sub[x];
        }
    }
}

// dst(x, y) = src(x - dx, y - dy), bilinear, replicate border (cv2.warpAffine / translate_bilinear).
void translate(const std::vector<float>& src, std::vector<float>& dst, int w, int h, float dx, float dy) {
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        const float sx = std::clamp(x - dx, 0.f, static_cast<float>(w - 1));
        const float sy = std::clamp(y - dy, 0.f, static_cast<float>(h - 1));
        const int x0 = static_cast<int>(sx), y0 = static_cast<int>(sy);
        const int x1 = std::min(x0 + 1, w - 1), y1 = std::min(y0 + 1, h - 1);
        const float fx = sx - x0, fy = sy - y0;
        const float top = src[y0 * w + x0] * (1 - fx) + src[y0 * w + x1] * fx;
        const float bot = src[y1 * w + x0] * (1 - fx) + src[y1 * w + x1] * fx;
        dst[y * w + x] = top * (1 - fy) + bot * fy;
    }
}

// Align-corners bilinear resample (upsample_bilinear).
void upsample(const std::vector<float>& src, int sw, int sh, std::vector<float>& dst, int w, int h) {
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        const float fx = w > 1 ? x * float(sw - 1) / float(w - 1) : 0.f;
        const float fy = h > 1 ? y * float(sh - 1) / float(h - 1) : 0.f;
        const int x0 = static_cast<int>(fx), y0 = static_cast<int>(fy);
        const int x1 = std::min(x0 + 1, sw - 1), y1 = std::min(y0 + 1, sh - 1);
        const float ax = fx - x0, ay = fy - y0;
        const float top = src[y0 * sw + x0] * (1 - ax) + src[y0 * sw + x1] * ax;
        const float bot = src[y1 * sw + x0] * (1 - ax) + src[y1 * sw + x1] * ax;
        dst[y * w + x] = top * (1 - ay) + bot * ay;
    }
}

// Area (block mean) downsample, as cv2.resize INTER_AREA for these integral-ish ratios.
void area(const std::vector<float>& src, int w, int h, std::vector<float>& dst, int dw, int dh) {
    dst.assign(static_cast<size_t>(dw) * dh, 0.f);
    for (int y = 0; y < dh; ++y) for (int x = 0; x < dw; ++x) {
        const int x0 = x * w / dw, x1 = std::max(x0 + 1, (x + 1) * w / dw);
        const int y0 = y * h / dh, y1 = std::max(y0 + 1, (y + 1) * h / dh);
        float acc = 0;
        for (int yy = y0; yy < y1; ++yy) for (int xx = x0; xx < x1; ++xx) acc += src[yy * w + xx];
        dst[y * dw + x] = acc / float((x1 - x0) * (y1 - y0));
    }
}
} // namespace

DepthStabilizer::DepthStabilizer(int width, int height) : w_(width), h_(height) {
    // Motion-comp working grid: at least /2, longest side <= 512 (PTMediaServer _MC_*).
    const int ds = std::max(2, (std::max(w_, h_) + 511) / 512);
    sw_ = std::max(8, w_ / ds);
    sh_ = std::max(8, h_ / ds);
    const size_t n = static_cast<size_t>(w_) * h_;
    near_.resize(n); base_cur_.resize(n); base_prev_.resize(n); base_warp_.resize(n); tmp_.resize(n); alpha_.resize(n);
    gray_.resize(n);
}

void DepthStabilizer::reset() {
    have_band_ = false; initialized_ = false; have_small_ = false;
    have_ref_ = false; cooldown_left_ = 0;
}

bool DepthStabilizer::scene_cut(const float* rgb, int frame_step) {
    // OpenCV HSV of 8-bit RGB: H in [0, 180), S in [0, 255]; 30 x 32 bins, L1-normalized.
    const size_t n = static_cast<size_t>(w_) * h_;
    std::vector<float> hist(30 * 32, 0.f);
    for (size_t p = 0; p < n; ++p) {
        const float r = rgb[p] * 255.f, g = rgb[n + p] * 255.f, b = rgb[2 * n + p] * 255.f;
        const float v = std::max({r, g, b}), mn = std::min({r, g, b}), c = v - mn;
        const float s = v > 0 ? c / v * 255.f : 0.f;
        float hue = 0;
        if (c > 0) {
            if (v == r) hue = 60.f * (g - b) / c;
            else if (v == g) hue = 120.f + 60.f * (b - r) / c;
            else hue = 240.f + 60.f * (r - g) / c;
            if (hue < 0) hue += 360.f;
        }
        const int hb = std::min(29, static_cast<int>(hue * 0.5f / 6.f));
        const int sb = std::min(31, static_cast<int>(s / 8.f));
        hist[hb * 32 + sb] += 1.f;
    }
    for (auto& v : hist) v /= static_cast<float>(n);
    if (!have_ref_) { ref_hist_ = hist; have_ref_ = true; return false; }
    const float keep = std::pow(kCutRefEma, static_cast<float>(std::max(1, frame_step)));
    auto update = [&] { for (size_t i = 0; i < hist.size(); ++i) ref_hist_[i] = ref_hist_[i] * keep + hist[i] * (1 - keep); };
    if (cooldown_left_ > 0) { cooldown_left_ = std::max(0, cooldown_left_ - frame_step); update(); return false; }
    float bc = 0;
    for (size_t i = 0; i < hist.size(); ++i) bc += std::sqrt(ref_hist_[i] * hist[i]);
    const float distance = std::sqrt(std::max(0.f, 1.f - bc));
    // A cut re-seeds the reference; PTMediaServer then resets the detector (and its cooldown) and
    // steps it again on the same frame, so no cooldown follows a cut.
    if (distance > kCutThreshold) { ref_hist_ = hist; cooldown_left_ = 0; return true; }
    update();
    return false;
}

void DepthStabilizer::band(const float* inv, int frame_step) {
    // Letterbox bars are not picture: they must not take part of the near band.
    const int x0 = cw_ > 0 ? cx_ : 0, y0 = cw_ > 0 ? cy_ : 0, x1 = cw_ > 0 ? cx_ + cw_ : w_, y1 = cw_ > 0 ? cy_ + ch_ : h_;
    std::vector<float> sorted;
    sorted.reserve(static_cast<size_t>(x1 - x0) * (y1 - y0));
    for (int y = y0; y < y1; ++y) for (int x = x0; x < x1; ++x) {
        const float v = inv[static_cast<size_t>(y) * w_ + x];
        if (std::isfinite(v)) sorted.push_back(v);
    }
    if (sorted.size() < 16) { have_band_ = false; return; }
    auto at = [&](float q) {
        auto nth = sorted.begin() + static_cast<long>(q * (sorted.size() - 1));
        std::nth_element(sorted.begin(), nth, sorted.end());
        return *nth;
    };
    const float plo = at(0.05f), phi = at(0.95f);
    if (!(phi > plo)) { have_band_ = false; return; }
    if (!have_band_) { lo_ = plo; hi_ = phi; have_band_ = true; return; }
    const float span = std::max(hi_ - lo_, 1e-6f);
    const float jump = std::max(std::fabs(plo - lo_), std::fabs(phi - hi_)) / span;
    if (jump >= kNormReset) {
        // As TemporalDepthStabilizer.normalization_band: a whole-band jump restarts everything.
        initialized_ = false; have_small_ = false;
        lo_ = plo; hi_ = phi; ++cuts_;
        return;
    }
    const float a = rate(std::min(1.f, kNormAlpha * speed_), frame_step);
    lo_ = (1 - a) * lo_ + a * plo;
    hi_ = (1 - a) * hi_ + a * phi;
}

void DepthStabilizer::phase_correlate(const std::vector<float>& a, const std::vector<float>& b, int w, int h,
                                      float* dx, float* dy, float* response) {
    thread_local PhaseWorkspace workspace;
    workspace.prepare(w, h);
    const int pw = workspace.pw, ph = workspace.ph;
    auto& fa = workspace.a; auto& fb = workspace.b;
    // Consecutive pairs share one image. Reuse its exact spectrum; compare values,
    // not addresses, because callers may swap buffers or interleave sessions.
    const bool cached = workspace.previous_input == a;
    if (cached) fa = fb; else std::fill(fa.begin(), fa.end(), cf());
    std::fill(fb.begin(), fb.end(), cf());
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        // cv2.createHanningWindow: 0.5 * (1 - cos(2 pi i / (n - 1))) per axis.
        const float win = workspace.window[y * w + x];
        if (!cached) fa[y * pw + x] = a[y * w + x] * win;
        fb[y * pw + x] = b[y * w + x] * win;
    }
    if (!cached) workspace.fft2(fa, false);
    workspace.fft2(fb, false);
    workspace.previous_input = b;
    for (size_t i = 0; i < fa.size(); ++i) {
        const cf c = fb[i] * cf(fa[i].r, -fa[i].i);
        const float mag = std::sqrt(c.r * c.r + c.i * c.i);
        fa[i] = mag > 1e-12f ? c / mag : cf(0.f, 0.f);
    }
    workspace.fft2(fa, true);
    const float scale = 1.f / (static_cast<float>(pw) * ph);
    int px = 0, py = 0; float best = -1e30f;
    for (int y = 0; y < ph; ++y) for (int x = 0; x < pw; ++x) {
        const float v = fa[y * pw + x].r * scale;
        if (v > best) { best = v; px = x; py = y; }
    }
    // 5 x 5 weighted centroid around the peak (cv2.phaseCorrelate), wrapping.
    float sum = 0, sx = 0, sy = 0;
    for (int oy = -2; oy <= 2; ++oy) for (int ox = -2; ox <= 2; ++ox) {
        const int x = (px + ox + pw) % pw, y = (py + oy + ph) % ph;
        const float v = fa[y * pw + x].r * scale;
        sum += v; sx += v * (px + ox); sy += v * (py + oy);
    }
    float cx = sum != 0 ? sx / sum : static_cast<float>(px);
    float cy = sum != 0 ? sy / sum : static_cast<float>(py);
    if (cx > pw / 2.f) cx -= pw;
    if (cy > ph / 2.f) cy -= ph;
    *dx = cx; *dy = cy; *response = sum;
}

void DepthStabilizer::stabilize(const float* rgb, int frame_step) {
    const size_t n = static_cast<size_t>(w_) * h_;
    int k = static_cast<int>(std::lround(std::min(w_, h_) / 16.0));
    if (k < 3) k = 3;
    if (k % 2 == 0) ++k;
    auto started = Clock::now();
    box(near_, tmp_, base_cur_, w_, h_, k);
    timing_.box_ms = elapsed(started);
    // Gray of the model input, then the motion-comp grid.
    std::vector<float> gray(n);
    for (size_t p = 0; p < n; ++p) {
        const float v = (0.299f * rgb[p] + 0.587f * rgb[n + p] + 0.114f * rgb[2 * n + p]) * 255.f;
        gray[p] = std::floor(std::clamp(v, 0.f, 255.f) + 0.5f);
    }
    std::vector<float> small;
    area(gray, w_, h_, small, sw_, sh_);
    if (!initialized_) {
        base_prev_ = base_cur_; small_prev_ = small; have_small_ = true; initialized_ = true;
        return; // first frame is identity: base + detail == near
    }
    // Global shift prev -> cur, motion-compensated previous base, per-tile evidence alpha.
    const std::vector<float>* prev = &base_prev_;
    bool alpha_map = false;
    last_dx_ = last_dy_ = 0; last_response_ = 0;
    if (have_small_) {
        float dxs = 0, dys = 0, response = 0;
        started = Clock::now();
        phase_correlate(small_prev_, small, sw_, sh_, &dxs, &dys, &response);
        timing_.motion_ms = elapsed(started);
        last_response_ = response;
        if (std::isfinite(response) && std::isfinite(dxs) && std::isfinite(dys) && response >= kMcMinResponse) {
            // Evidence gate on the small grid: residual between cur and the shifted previous gray.
            std::vector<float> aligned = small_prev_;
            if (std::fabs(dxs) >= 0.5f || std::fabs(dys) >= 0.5f) translate(small_prev_, aligned, sw_, sh_, dxs, dys);
            std::vector<float> resid(small.size());
            for (size_t i = 0; i < small.size(); ++i) resid[i] = std::fabs(small[i] - aligned[i]);
            const int tile = 16 / 2; // _EVID_TILE // _MC_DOWNSAMPLE
            const int tw = std::max(1, sw_ / tile), th = std::max(1, sh_ / tile);
            std::vector<float> coarse, back(small.size());
            area(resid, sw_, sh_, coarse, tw, th);
            // cv2.resize INTER_LINEAR (half-pixel centers) back to the small grid.
            for (int y = 0; y < sh_; ++y) for (int x = 0; x < sw_; ++x) {
                const float fx = std::clamp((x + 0.5f) * tw / float(sw_) - 0.5f, 0.f, float(tw - 1));
                const float fy = std::clamp((y + 0.5f) * th / float(sh_) - 0.5f, 0.f, float(th - 1));
                const int x0 = static_cast<int>(fx), y0 = static_cast<int>(fy);
                const int x1 = std::min(x0 + 1, tw - 1), y1 = std::min(y0 + 1, th - 1);
                const float ax = fx - x0, ay = fy - y0;
                back[y * sw_ + x] = (coarse[y0 * tw + x0] * (1 - ax) + coarse[y0 * tw + x1] * ax) * (1 - ay)
                                  + (coarse[y1 * tw + x0] * (1 - ax) + coarse[y1 * tw + x1] * ax) * ay;
            }
            const float lock = std::min(1.f, kDepthAlpha * speed_) * kEvidenceLock;
            std::vector<float> alpha_small(small.size());
            for (size_t i = 0; i < small.size(); ++i) {
                const float t = std::clamp((back[i] - kEvidLo) / std::max(1e-3f, kEvidHi - kEvidLo), 0.f, 1.f);
                alpha_small[i] = lock + (1 - lock) * t;
            }
            upsample(alpha_small, sw_, sh_, alpha_, w_, h_);
            alpha_map = true;
            const float dx = std::clamp(dxs * (float(w_) / float(sw_)), -kMcMaxShift, kMcMaxShift);
            const float dy = std::clamp(dys * (float(h_) / float(sh_)), -kMcMaxShift, kMcMaxShift);
            last_dx_ = dx; last_dy_ = dy;
            if (std::fabs(dx) >= 0.5f || std::fabs(dy) >= 0.5f) {
                translate(base_prev_, base_warp_, w_, h_, dx, dy);
                prev = &base_warp_;
            }
        }
    }
    // Bounded affine match of the current base to the previous one (moments, as the GPU path).
    started = Clock::now();
    double count = 0, sc = 0, sp = 0, sc2 = 0, sp2 = 0;
    for (size_t p = 0; p < n; ++p) {
        const float c = base_cur_[p], q = (*prev)[p];
        if (c > 0.02f && c < 0.98f && q > 0.02f && q < 0.98f) { count += 1; sc += c; sp += q; sc2 += c * c; sp2 += q * q; }
    }
    float scale = 1, bias = 0;
    if (count >= std::max(128.0, n * 0.05)) {
        const double mc = sc / count, mp = sp / count;
        const double vc = std::max(sc2 / count - mc * mc, 0.0), vp = std::max(sp2 / count - mp * mp, 0.0);
        if (vc > 1e-6 && vp > 1e-6) {
            scale = std::clamp(static_cast<float>(std::sqrt(vp / vc)), 1 - kAffineMaxScale, 1 + kAffineMaxScale);
            bias = std::clamp(static_cast<float>(mp - scale * mc), -kAffineMaxBias, kAffineMaxBias);
        }
    }
    const float fixed = rate(std::min(1.f, kDepthAlpha * speed_), frame_step);
    std::vector<float> next(n);
    for (size_t p = 0; p < n; ++p) {
        const float a = alpha_map ? rate(alpha_[p], frame_step) : fixed;
        const float aligned = std::clamp(base_cur_[p] * scale + bias, 0.f, 1.f);
        const float stable = std::clamp((*prev)[p] * (1 - a) + aligned * a, 0.f, 1.f);
        next[p] = stable;
        near_[p] = std::clamp(stable + (near_[p] - base_cur_[p]), 0.f, 1.f);
    }
    base_prev_.swap(next);
    small_prev_.swap(small);
    have_small_ = true;
    timing_.blend_ms = elapsed(started);
}

void DepthStabilizer::process(const float* inv, const float* rgb, int frame_step, float* near) {
    const size_t n = static_cast<size_t>(w_) * h_;
    frame_step = std::max(1, frame_step);
    timing_ = {};
    auto started = Clock::now();
    last_cut_ = scene_cut(rgb, frame_step);
    timing_.scene_ms = elapsed(started);
    if (last_cut_) { have_band_ = false; initialized_ = false; have_small_ = false; ++cuts_; }
    started = Clock::now();
    band(inv, frame_step);
    timing_.band_ms = elapsed(started);
    if (!have_band_) { std::fill(near, near + n, 0.f); initialized_ = false; return; }
    const float s = hi_ - lo_ > 1e-12f ? 1.f / (hi_ - lo_) : 0.f;
    for (size_t p = 0; p < n; ++p)
        near_[p] = std::isfinite(inv[p]) ? std::clamp((inv[p] - lo_) * s, 0.f, 1.f) : 0.f;
    started = Clock::now();
    stabilize(rgb, frame_step);
    timing_.stabilize_ms = elapsed(started);
    // soft_shift: grow the foreground by round(w / 512) (at least 1) so the gap is bounded by background.
    const int r = dilation_ >= 0 ? dilation_ : std::max(1, static_cast<int>(std::lround(w_ / 512.0)));
    if (r == 0) { std::copy(near_.begin(), near_.end(), near); return; }
    started = Clock::now();
    if (r == 1 && w_ >= 2) {
        for (int y = 0; y < h_; ++y) {
            const float* row = near_.data() + y * w_;
            float* dst = tmp_.data() + y * w_;
            dst[0] = std::max(row[0], row[1]);
            for (int x = 1; x < w_ - 1; ++x) dst[x] = std::max(row[x - 1], std::max(row[x], row[x + 1]));
            dst[w_ - 1] = std::max(row[w_ - 2], row[w_ - 1]);
        }
        for (int y = 0; y < h_; ++y) {
            const float* top = tmp_.data() + std::max(y - 1, 0) * w_;
            const float* row = tmp_.data() + y * w_;
            const float* bottom = tmp_.data() + std::min(y + 1, h_ - 1) * w_;
            for (int x = 0; x < w_; ++x) near[y * w_ + x] = std::max(top[x], std::max(row[x], bottom[x]));
        }
        timing_.dilation_ms = elapsed(started);
        return;
    }
    for (int y = 0; y < h_; ++y) for (int x = 0; x < w_; ++x) {
        float m = 0;
        for (int dy = -r; dy <= r; ++dy) for (int dx = -r; dx <= r; ++dx)
            m = std::max(m, near_[std::clamp(y + dy, 0, h_ - 1) * w_ + std::clamp(x + dx, 0, w_ - 1)]);
        near[y * w_ + x] = m;
    }
    timing_.dilation_ms = elapsed(started);
}

} // namespace quest
