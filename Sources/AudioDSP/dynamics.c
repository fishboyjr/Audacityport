/* Compressor, noise gate, look-ahead limiter. */
#include "AudioDSP.h"
#include "dsp_internal.h"
#include <math.h>
#include <stdlib.h>

static inline float db_to_lin(float db) { return powf(10.0f, db / 20.0f); }
static inline float lin_to_db(float l) { return l > 1e-9f ? 20.0f * log10f(l) : -180.0f; }

static inline double time_coef(double ms, double fs) {
    if (ms <= 0) return 0.0;
    return exp(-1.0 / (ms * 0.001 * fs));
}

void adsp_compress(float *buf, size_t n, double fs, const adsp_compressor_params *p) {
    if (n == 0 || p->ratio <= 1.0f) {
        if (p->auto_makeup) adsp_normalize(buf, n, 0.0f, 0);
        return;
    }
    double att = time_coef(p->attack_ms, fs);
    double rel = time_coef(p->release_ms, fs);
    double env_db = -180.0; /* envelope of the level in dB */
    double slope = 1.0 - 1.0 / p->ratio;
    float makeup = db_to_lin(p->makeup_db);
    for (size_t i = 0; i < n; i++) {
        double lvl = lin_to_db(fabsf(buf[i]));
        double c = lvl > env_db ? att : rel;
        env_db = c * env_db + (1.0 - c) * lvl;
        double over = env_db - p->threshold_db;
        double gr_db = over > 0 ? -over * slope : 0.0;
        buf[i] *= (float)pow(10.0, gr_db / 20.0) * makeup;
    }
    if (p->auto_makeup) adsp_normalize(buf, n, 0.0f, 0);
}

void adsp_noise_gate(float *buf, size_t n, double fs, float threshold_db, float reduction_db,
                     float attack_ms, float hold_ms, float release_ms) {
    float thr = db_to_lin(threshold_db);
    float floor_gain = db_to_lin(-fabsf(reduction_db));
    double att = time_coef(attack_ms, fs);  /* gate opening */
    double rel = time_coef(release_ms, fs); /* gate closing */
    double env_rel = time_coef(10.0, fs);   /* level detector release */
    size_t hold = (size_t)(hold_ms * 0.001 * fs);
    size_t hold_left = 0;
    double env = 0.0, g = floor_gain;
    for (size_t i = 0; i < n; i++) {
        double a = fabsf(buf[i]);
        env = a > env ? a : env_rel * env + (1.0 - env_rel) * a;
        double target;
        if (env >= thr) { target = 1.0; hold_left = hold; }
        else if (hold_left > 0) { target = 1.0; hold_left--; }
        else target = floor_gain;
        double c = target > g ? att : rel;
        g = c * g + (1.0 - c) * target;
        buf[i] *= (float)g;
    }
}

void adsp_limit(float *buf, size_t n, double fs, float ceiling_db, float release_ms) {
    if (n == 0) return;
    float ceil_lin = db_to_lin(ceiling_db);
    size_t L = (size_t)(0.005 * fs); /* 5 ms look-ahead */
    if (L < 1) L = 1;
    float *g = malloc(n * sizeof(float));
    float *m = malloc(n * sizeof(float));
    size_t *dq = malloc(n * sizeof(size_t));
    if (!g || !m || !dq) { free(g); free(m); free(dq); adsp_hard_clip(buf, n, ceil_lin); return; }

    for (size_t i = 0; i < n; i++) {
        float a = fabsf(buf[i]);
        g[i] = a > ceil_lin ? ceil_lin / a : 1.0f;
    }
    /* m[i] = min g[j] for j in [i-L, i+L], via monotonic deque. */
    size_t head = 0, tail = 0, next = 0;
    for (size_t i = 0; i < n; i++) {
        size_t hi = i + L < n ? i + L : n - 1;
        while (next <= hi) {
            while (tail > head && g[dq[tail - 1]] >= g[next]) tail--;
            dq[tail++] = next++;
        }
        size_t lo = i >= L ? i - L : 0;
        while (dq[head] < lo) head++;
        m[i] = g[dq[head]];
    }
    /* Release smoothing: r never exceeds m. */
    double rc = time_coef(release_ms, fs);
    double r = 1.0;
    for (size_t i = 0; i < n; i++) {
        if (m[i] < r) r = m[i];
        else r = r + (m[i] - r) * (1.0 - rc);
        g[i] = (float)r;
    }
    /* Centred moving average of length 2L+1 keeps gain <= required at each sample. */
    double acc = 0.0;
    size_t win = 0;
    for (size_t i = 0; i < n && i <= L; i++) { acc += g[i]; win++; }
    for (size_t i = 0; i < n; i++) {
        float gi = (float)(acc / (double)win);
        buf[i] *= gi;
        size_t add = i + L + 1;
        if (add < n) { acc += g[add]; win++; }
        if (i >= L) { acc -= g[i - L]; win--; }
    }
    adsp_hard_clip(buf, n, ceil_lin); /* guard against rounding */
    free(g); free(m); free(dq);
}
