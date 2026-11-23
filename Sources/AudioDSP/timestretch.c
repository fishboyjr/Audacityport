/* Resampling (Change Speed), WSOLA time stretch (Change Tempo), pitch shift. */
#include "AudioDSP.h"
#include "dsp_internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define LANCZOS_A 8

static inline double sinc(double x) {
    if (fabs(x) < 1e-9) return 1.0;
    double px = M_PI * x;
    return sin(px) / px;
}

size_t adsp_resample_length(size_t n, double speed) {
    if (speed <= 0) return 0;
    return (size_t)llround((double)n / speed);
}

size_t adsp_resample(const float *in, size_t n, double speed, float *out, size_t out_cap) {
    size_t m = adsp_resample_length(n, speed);
    if (m > out_cap) m = out_cap;
    if (n == 0) return 0;
    /* When decimating, widen the kernel and lower the cutoff to avoid aliasing. */
    double cutoff = speed > 1.0 ? 1.0 / speed : 1.0;
    double hw = LANCZOS_A / cutoff;
    for (size_t j = 0; j < m; j++) {
        double x = (double)j * speed;
        long lo = (long)floor(x - hw) + 1;
        long hi = (long)floor(x + hw);
        if (lo < 0) lo = 0;
        if (hi > (long)n - 1) hi = (long)n - 1;
        double acc = 0.0, wsum = 0.0;
        for (long k = lo; k <= hi; k++) {
            double t = (x - (double)k) * cutoff;
            double wgt = sinc(t) * sinc(t / LANCZOS_A);
            acc += in[k] * wgt;
            wsum += wgt;
        }
        /* Normalising by the kernel sum keeps DC gain exactly 1 (also at edges). */
        out[j] = wsum != 0.0 ? (float)(acc / wsum) : 0.0f;
    }
    return m;
}

size_t adsp_time_stretch_length(size_t n, double tempo) {
    if (tempo <= 0) return 0;
    return (size_t)llround((double)n / tempo);
}

static inline float sample_at(const float *in, size_t n, long i) {
    return (i >= 0 && (size_t)i < n) ? in[i] : 0.0f;
}

size_t adsp_time_stretch(const float *in, size_t n, double tempo, int sr,
                         float *out, size_t out_cap) {
    size_t m = adsp_time_stretch_length(n, tempo);
    if (m > out_cap) m = out_cap;
    if (m == 0) return 0;
    if (fabs(tempo - 1.0) < 1e-9) {
        memcpy(out, in, (m < n ? m : n) * sizeof(float));
        if (m > n) memset(out + n, 0, (m - n) * sizeof(float));
        return m;
    }
    long N = (long)(sr * 0.04);          /* 40 ms frames */
    if (N < 64) N = 64;
    N &= ~1L;
    long Hs = N / 2;                      /* synthesis hop */
    double Ha = Hs * tempo;               /* analysis hop */
    long delta = (long)(sr * 0.008);      /* +/- 8 ms search window */
    if (delta < 4) delta = 4;

    float *w = malloc((size_t)N * sizeof(float));
    if (!w) return 0;
    for (long i = 0; i < N; i++) w[i] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * (double)i / (double)N));
    memset(out, 0, m * sizeof(float));

    long prev = 0;
    for (long k = 0; k * Hs < (long)m; k++) {
        long pos;
        if (k == 0) {
            pos = 0;
        } else {
            long nominal = (long)llround(k * Ha);
            long natural = prev + Hs; /* where the previous frame would continue */
            double best = -1e300;
            pos = nominal;
            for (long off = -delta; off <= delta; off += 2) {
                long cand = nominal + off;
                if (cand < 0) continue;
                double c = 0.0;
                for (long i = 0; i < Hs; i += 4)
                    c += (double)sample_at(in, n, cand + i) * sample_at(in, n, natural + i);
                if (c > best) { best = c; pos = cand; }
            }
        }
        long base = k * Hs;
        for (long i = 0; i < N && base + i < (long)m; i++) {
            float wi = (k == 0 && i < Hs) ? 1.0f : w[i];
            out[base + i] += wi * sample_at(in, n, pos + i);
        }
        prev = pos;
    }
    free(w);
    return m;
}

size_t adsp_pitch_shift(const float *in, size_t n, double semitones, int sr, float *out) {
    if (n == 0) return 0;
    double ratio = pow(2.0, semitones / 12.0);
    size_t stretched_len = adsp_time_stretch_length(n, 1.0 / ratio);
    float *tmp = malloc((stretched_len + 1) * sizeof(float));
    if (!tmp) return 0;
    size_t s = adsp_time_stretch(in, n, 1.0 / ratio, sr, tmp, stretched_len);
    size_t r = adsp_resample(tmp, s, ratio, out, n);
    if (r < n) memset(out + r, 0, (n - r) * sizeof(float));
    free(tmp);
    return n;
}
