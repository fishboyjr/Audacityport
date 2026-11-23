/* Tone, noise and DTMF generators. */
#include "AudioDSP.h"
#include "dsp_internal.h"
#include <math.h>
#include <string.h>

void adsp_generate_tone(float *buf, size_t n, double fs, adsp_waveform wave, double freq, float amp) {
    double phase = 0.0, inc = freq / fs;
    for (size_t i = 0; i < n; i++) {
        double v;
        switch (wave) {
        case ADSP_WAVE_SQUARE: v = phase < 0.5 ? 1.0 : -1.0; break;
        case ADSP_WAVE_SAWTOOTH: v = 2.0 * phase - 1.0; break;
        case ADSP_WAVE_TRIANGLE: v = phase < 0.5 ? 4.0 * phase - 1.0 : 3.0 - 4.0 * phase; break;
        case ADSP_WAVE_SINE:
        default: v = sin(2.0 * M_PI * phase); break;
        }
        buf[i] = (float)(v * amp);
        phase += inc;
        phase -= floor(phase);
    }
}

static inline uint32_t xorshift32(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *s = x;
}

static inline float rand_bipolar(uint32_t *s) {
    return (float)((double)xorshift32(s) / 4294967295.0 * 2.0 - 1.0);
}

void adsp_generate_noise(float *buf, size_t n, adsp_noise_type type, float amp, uint32_t seed) {
    uint32_t s = seed ? seed : 0x9E3779B9u;
    if (type == ADSP_NOISE_PINK) {
        /* Paul Kellet's refined pink filter. */
        double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
        for (size_t i = 0; i < n; i++) {
            double w = rand_bipolar(&s);
            b0 = 0.99886 * b0 + w * 0.0555179;
            b1 = 0.99332 * b1 + w * 0.0750759;
            b2 = 0.96900 * b2 + w * 0.1538520;
            b3 = 0.86650 * b3 + w * 0.3104856;
            b4 = 0.55000 * b4 + w * 0.5329522;
            b5 = -0.7616 * b5 - w * 0.0168980;
            double p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362;
            b6 = w * 0.115926;
            buf[i] = (float)(p * 0.11 * amp);
        }
    } else if (type == ADSP_NOISE_BROWN) {
        double y = 0;
        for (size_t i = 0; i < n; i++) {
            y = (y + 0.02 * rand_bipolar(&s)) / 1.02;
            buf[i] = (float)(y * 3.5 * amp);
        }
    } else {
        for (size_t i = 0; i < n; i++) buf[i] = rand_bipolar(&s) * amp;
    }
    adsp_hard_clip(buf, n, 1.0f);
}

int adsp_generate_dtmf(float *buf, size_t n, double fs, char key, float amp) {
    static const char *layout = "123A456B789C*0#D";
    static const double rows[4] = {697, 770, 852, 941};
    static const double cols[4] = {1209, 1336, 1477, 1633};
    const char *p = strchr(layout, key);
    if (!p || key == 0) return -1;
    int idx = (int)(p - layout);
    double fr = rows[idx / 4], fc = cols[idx % 4];
    for (size_t i = 0; i < n; i++) {
        double t = (double)i / fs;
        buf[i] = (float)(0.5 * amp * (sin(2 * M_PI * fr * t) + sin(2 * M_PI * fc * t)));
    }
    return 0;
}
