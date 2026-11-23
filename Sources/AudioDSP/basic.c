/* Analysis, basic in-place effects, mixing. */
#include "AudioDSP.h"
#include "dsp_internal.h"
#include <math.h>
#include <string.h>

float adsp_peak(const float *buf, size_t n) {
    float p = 0.0f;
    for (size_t i = 0; i < n; i++) {
        float a = fabsf(buf[i]);
        if (a > p) p = a;
    }
    return p;
}

float adsp_rms(const float *buf, size_t n) {
    if (n == 0) return 0.0f;
    double s = 0.0;
    for (size_t i = 0; i < n; i++) s += (double)buf[i] * buf[i];
    return (float)sqrt(s / (double)n);
}

float adsp_mean(const float *buf, size_t n) {
    if (n == 0) return 0.0f;
    double s = 0.0;
    for (size_t i = 0; i < n; i++) s += buf[i];
    return (float)(s / (double)n);
}

void adsp_summarize(const float *buf, size_t start, size_t count, size_t columns,
                    float *out_min, float *out_max, float *out_rms) {
    if (columns == 0) return;
    for (size_t c = 0; c < columns; c++) {
        size_t a = start + (size_t)((double)count * c / columns);
        size_t b = start + (size_t)((double)count * (c + 1) / columns);
        if (b <= a) b = a + 1;
        if (count == 0) { a = b = start; }
        float mn = 0.0f, mx = 0.0f;
        double ss = 0.0;
        if (b > a && count > 0) {
            mn = mx = buf[a];
            for (size_t i = a; i < b && i < start + count; i++) {
                float v = buf[i];
                if (v < mn) mn = v;
                if (v > mx) mx = v;
                ss += (double)v * v;
            }
        }
        size_t len = (b > a) ? (b - a) : 1;
        if (out_min) out_min[c] = mn;
        if (out_max) out_max[c] = mx;
        if (out_rms) out_rms[c] = (float)sqrt(ss / (double)len);
    }
}

void adsp_gain(float *buf, size_t n, float gain) {
    for (size_t i = 0; i < n; i++) buf[i] *= gain;
}

float adsp_normalize_gain(const float *buf, size_t n, float target_db) {
    float p = adsp_peak(buf, n);
    if (p <= 1e-12f) return 1.0f;
    return powf(10.0f, target_db / 20.0f) / p;
}

void adsp_remove_dc(float *buf, size_t n) {
    float m = adsp_mean(buf, n);
    for (size_t i = 0; i < n; i++) buf[i] -= m;
}

void adsp_normalize(float *buf, size_t n, float target_db, int remove_dc) {
    if (remove_dc) adsp_remove_dc(buf, n);
    adsp_gain(buf, n, adsp_normalize_gain(buf, n, target_db));
}

static double fade_curve(double t, adsp_fade_curve curve) {
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    switch (curve) {
    case ADSP_FADE_EXPONENTIAL: return t * t;
    case ADSP_FADE_LOGARITHMIC: return sqrt(t);
    case ADSP_FADE_SCURVE: return 0.5 - 0.5 * cos(M_PI * t);
    case ADSP_FADE_LINEAR:
    default: return t;
    }
}

void adsp_fade_in(float *buf, size_t n, adsp_fade_curve curve) {
    if (n == 0) return;
    if (n == 1) { buf[0] = 0.0f; return; }
    for (size_t i = 0; i < n; i++)
        buf[i] *= (float)fade_curve((double)i / (double)(n - 1), curve);
}

void adsp_fade_out(float *buf, size_t n, adsp_fade_curve curve) {
    if (n == 0) return;
    if (n == 1) { buf[0] = 0.0f; return; }
    for (size_t i = 0; i < n; i++)
        buf[i] *= (float)fade_curve(1.0 - (double)i / (double)(n - 1), curve);
}

void adsp_reverse(float *buf, size_t n) {
    if (n < 2) return;
    for (size_t i = 0, j = n - 1; i < j; i++, j--) {
        float t = buf[i];
        buf[i] = buf[j];
        buf[j] = t;
    }
}

void adsp_invert(float *buf, size_t n) {
    for (size_t i = 0; i < n; i++) buf[i] = -buf[i];
}

void adsp_silence(float *buf, size_t n) {
    if (n) memset(buf, 0, n * sizeof(float));
}

size_t adsp_hard_clip(float *buf, size_t n, float limit) {
    size_t c = 0;
    for (size_t i = 0; i < n; i++) {
        if (buf[i] > limit) { buf[i] = limit; c++; }
        else if (buf[i] < -limit) { buf[i] = -limit; c++; }
    }
    return c;
}

void adsp_echo(float *buf, size_t n, size_t delay_samples, float decay) {
    if (delay_samples == 0) return;
    for (size_t i = delay_samples; i < n; i++) buf[i] += buf[i - delay_samples] * decay;
}

void adsp_mix_into(float *dst, const float *src, size_t n, float gain, float pan, int ch, int channels) {
    float g = gain;
    if (channels >= 2) {
        /* Linear balance law: centre leaves both channels at unity. */
        if (pan > 1) pan = 1;
        if (pan < -1) pan = -1;
        if (ch == 0 && pan > 0) g *= 1.0f - pan;
        if (ch == 1 && pan < 0) g *= 1.0f + pan;
    }
    for (size_t i = 0; i < n; i++) dst[i] += src[i] * g;
}
