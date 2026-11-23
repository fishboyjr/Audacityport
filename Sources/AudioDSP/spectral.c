/* FFT, spectrum analysis, spectral-subtraction noise reduction. */
#include "AudioDSP.h"
#include "dsp_internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int is_pow2(size_t n) { return n >= 2 && (n & (n - 1)) == 0; }

int adsp_fft(float *re, float *im, size_t n, int inverse) {
    if (!is_pow2(n)) return -1;
    /* Bit reversal permutation. */
    for (size_t i = 1, j = 0; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        double ang = 2.0 * M_PI / (double)len * (inverse ? 1.0 : -1.0);
        double wr = cos(ang), wi = sin(ang);
        for (size_t i = 0; i < n; i += len) {
            double cr = 1.0, ci = 0.0;
            for (size_t k = 0; k < len / 2; k++) {
                size_t a = i + k, b = a + len / 2;
                double xr = re[b] * cr - im[b] * ci;
                double xi = re[b] * ci + im[b] * cr;
                re[b] = (float)(re[a] - xr); im[b] = (float)(im[a] - xi);
                re[a] = (float)(re[a] + xr); im[a] = (float)(im[a] + xi);
                double ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
    if (inverse) {
        float s = 1.0f / (float)n;
        for (size_t i = 0; i < n; i++) { re[i] *= s; im[i] *= s; }
    }
    return 0;
}

static void hann(float *w, size_t n) {
    for (size_t i = 0; i < n; i++) w[i] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * (double)i / (double)n));
}

/* Accumulate windowed magnitude (or power) spectra frame by frame. */
static int average_spectrum(const float *buf, size_t n, size_t N, float *out, int power) {
    if (!is_pow2(N)) return -1;
    size_t bins = N / 2 + 1;
    float *w = malloc(N * sizeof(float));
    float *re = malloc(N * sizeof(float));
    float *im = malloc(N * sizeof(float));
    double *acc = calloc(bins, sizeof(double));
    if (!w || !re || !im || !acc) { free(w); free(re); free(im); free(acc); return -2; }
    hann(w, N);
    size_t hop = N / 2, frames = 0;
    for (size_t s = 0; s == 0 || s + N <= n; s += hop) {
        for (size_t i = 0; i < N; i++) {
            re[i] = (s + i < n) ? buf[s + i] * w[i] : 0.0f;
            im[i] = 0.0f;
        }
        adsp_fft(re, im, N, 0);
        for (size_t b = 0; b < bins; b++) {
            double p = (double)re[b] * re[b] + (double)im[b] * im[b];
            acc[b] += power ? p : sqrt(p);
        }
        frames++;
        if (n < N) break;
    }
    for (size_t b = 0; b < bins; b++) out[b] = (float)(acc[b] / (double)frames);
    free(w); free(re); free(im); free(acc);
    return 0;
}

int adsp_noise_profile(const float *noise, size_t n, size_t N, float *out_profile) {
    return average_spectrum(noise, n, N, out_profile, 0);
}

int adsp_spectrum_db(const float *buf, size_t n, size_t N, float *out_db) {
    int r = average_spectrum(buf, n, N, out_db, 1);
    if (r) return r;
    /* Hann coherent gain is N/2: a full-scale sine reads ~0 dB. */
    double norm = (double)N / 2.0;
    for (size_t b = 0; b < N / 2 + 1; b++) {
        double p = out_db[b] / (norm * norm);
        out_db[b] = p > 1e-20 ? (float)(10.0 * log10(p)) : -200.0f;
    }
    return 0;
}

int adsp_noise_reduce(float *buf, size_t n, size_t N, const float *profile,
                      float reduction_db, float sensitivity, int smoothing_bands) {
    if (!is_pow2(N) || n == 0) return -1;
    size_t bins = N / 2 + 1, hop = N / 4;
    float atten = powf(10.0f, -fabsf(reduction_db) / 20.0f);
    size_t padded = n + 2 * N;
    float *w = malloc(N * sizeof(float));
    float *re = malloc(N * sizeof(float));
    float *im = malloc(N * sizeof(float));
    float *gain = malloc(bins * sizeof(float));
    float *sm = malloc(bins * sizeof(float));
    float *prev = malloc(bins * sizeof(float));
    float *in = calloc(padded, sizeof(float));
    float *out = calloc(padded, sizeof(float));
    if (!w || !re || !im || !gain || !sm || !prev || !in || !out) {
        free(w); free(re); free(im); free(gain); free(sm); free(prev); free(in); free(out);
        return -2;
    }
    hann(w, N);
    memcpy(in + N, buf, n * sizeof(float));
    for (size_t b = 0; b < bins; b++) prev[b] = atten;
    /* Per-frame release so gains recover smoothly (reduces "musical noise"). */
    const float release = 0.6f;

    for (size_t s = 0; s + N <= padded; s += hop) {
        for (size_t i = 0; i < N; i++) { re[i] = in[s + i] * w[i]; im[i] = 0.0f; }
        adsp_fft(re, im, N, 0);
        for (size_t b = 0; b < bins; b++) {
            float mag = sqrtf(re[b] * re[b] + im[b] * im[b]);
            gain[b] = (mag > profile[b] * sensitivity) ? 1.0f : atten;
        }
        /* Frequency smoothing of the mask. */
        for (size_t b = 0; b < bins; b++) {
            int lo = (int)b - smoothing_bands, hi = (int)b + smoothing_bands;
            if (lo < 0) lo = 0;
            if (hi > (int)bins - 1) hi = (int)bins - 1;
            float acc = 0;
            for (int k = lo; k <= hi; k++) acc += gain[k];
            sm[b] = acc / (float)(hi - lo + 1);
        }
        /* Time smoothing: instant attack (open), exponential release (close). */
        for (size_t b = 0; b < bins; b++) {
            float g = sm[b];
            float decayed = prev[b] * release + atten * (1.0f - release);
            if (g < decayed) g = decayed;
            prev[b] = g;
            re[b] *= g; im[b] *= g;
            if (b > 0 && b < N / 2) { re[N - b] *= g; im[N - b] *= g; }
        }
        adsp_fft(re, im, N, 1);
        for (size_t i = 0; i < N; i++) out[s + i] += re[i] * w[i];
    }
    /* Hann^2 at 75% overlap sums to 1.5. */
    const float norm = 1.0f / 1.5f;
    for (size_t i = 0; i < n; i++) buf[i] = out[N + i] * norm;

    free(w); free(re); free(im); free(gain); free(sm); free(prev); free(in); free(out);
    return 0;
}
