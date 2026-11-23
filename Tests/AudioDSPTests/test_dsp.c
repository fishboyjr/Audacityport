/*
 * Host-side unit tests for the C DSP core.
 *   make -C Tests/AudioDSPTests      (or: make test at repo root)
 */
#include "AudioDSP.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define NEAR(a, b, tol) (fabs((double)(a) - (double)(b)) <= (tol))

static const double FS = 44100.0;

static float *alloc_f(size_t n) { return calloc(n, sizeof(float)); }

/* Estimate dominant frequency with zero-crossings (good enough for pure tones). */
static double zc_freq(const float *b, size_t n, double fs) {
    size_t z = 0;
    for (size_t i = 1; i < n; i++) if ((b[i - 1] < 0) != (b[i] < 0)) z++;
    return (double)z / 2.0 / ((double)n / fs);
}

static void test_analysis(void) {
    float b[4] = {0.5f, -1.0f, 0.25f, 0.25f};
    CHECK(NEAR(adsp_peak(b, 4), 1.0, 1e-7), "peak");
    CHECK(NEAR(adsp_mean(b, 4), 0.0, 1e-7), "mean");
    CHECK(NEAR(adsp_rms(b, 4), sqrt((0.25 + 1 + 0.0625 + 0.0625) / 4), 1e-6), "rms");
    float mn[2], mx[2], rm[2];
    adsp_summarize(b, 0, 4, 2, mn, mx, rm);
    CHECK(mn[0] == -1.0f && mx[0] == 0.5f, "summary bin0 %f %f", mn[0], mx[0]);
    CHECK(mn[1] == 0.25f && mx[1] == 0.25f, "summary bin1");
}

static void test_basic(void) {
    size_t n = 1000;
    float *b = alloc_f(n);
    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 441, 0.25f);
    adsp_normalize(b, n, -1.0f, 1);
    CHECK(NEAR(adsp_peak(b, n), pow(10, -1.0 / 20), 1e-4), "normalize -1dB peak=%f", adsp_peak(b, n));

    for (size_t i = 0; i < n; i++) b[i] = 1.0f;
    adsp_fade_in(b, n, ADSP_FADE_LINEAR);
    CHECK(b[0] == 0.0f && NEAR(b[n - 1], 1, 1e-6) && NEAR(b[n / 2], 0.5, 0.01), "fade in");
    for (size_t i = 0; i < n; i++) b[i] = 1.0f;
    adsp_fade_out(b, n, ADSP_FADE_SCURVE);
    CHECK(NEAR(b[0], 1, 1e-6) && b[n - 1] == 0.0f, "fade out");

    for (size_t i = 0; i < n; i++) b[i] = (float)i;
    adsp_reverse(b, n);
    CHECK(b[0] == (float)(n - 1) && b[n - 1] == 0.0f, "reverse");
    adsp_invert(b, n);
    CHECK(b[0] == -(float)(n - 1), "invert");

    for (size_t i = 0; i < n; i++) b[i] = 0.3f;
    adsp_remove_dc(b, n);
    CHECK(NEAR(adsp_peak(b, n), 0, 1e-6), "dc removal");

    memset(b, 0, n * sizeof(float));
    b[0] = 1.0f;
    adsp_echo(b, n, 100, 0.5f);
    CHECK(NEAR(b[100], 0.5, 1e-6) && NEAR(b[200], 0.25, 1e-6), "echo");

    float d[2] = {0, 0}, s[2] = {1, 1};
    adsp_mix_into(d, s, 2, 1.0f, 0.5f, 0, 2);
    CHECK(NEAR(d[0], 0.5, 1e-6), "pan left attenuated");
    d[0] = d[1] = 0;
    adsp_mix_into(d, s, 2, 1.0f, 0.5f, 1, 2);
    CHECK(NEAR(d[0], 1.0, 1e-6), "pan right unity");
    free(b);
}

static void test_filters(void) {
    adsp_biquad bq;
    adsp_biquad_design(&bq, ADSP_BQ_LOWPASS, FS, 1000, 0.7071, 0);
    CHECK(NEAR(adsp_biquad_response_db(&bq, FS, 1000), -3.01, 0.05), "lpf -3dB at fc");
    CHECK(adsp_biquad_response_db(&bq, FS, 10000) < -35, "lpf stopband");
    CHECK(NEAR(adsp_biquad_response_db(&bq, FS, 20), 0, 0.01), "lpf passband");

    adsp_biquad_design(&bq, ADSP_BQ_PEAK, FS, 2000, 1, 6);
    CHECK(NEAR(adsp_biquad_response_db(&bq, FS, 2000), 6, 0.01), "peak +6");
    adsp_biquad_design(&bq, ADSP_BQ_LOWSHELF, FS, 250, 0.7071, 10);
    CHECK(NEAR(adsp_biquad_response_db(&bq, FS, 20), 10, 0.2), "low shelf");
    CHECK(NEAR(adsp_biquad_response_db(&bq, FS, 10000), 0, 0.1), "low shelf top");

    /* Time-domain check: highpass kills a 50 Hz tone, passes 5 kHz. */
    size_t n = 44100;
    float *b = alloc_f(n);
    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 50, 1);
    adsp_biquad_design(&bq, ADSP_BQ_HIGHPASS, FS, 2000, 0.7071, 0);
    adsp_biquad_process(&bq, b, n);
    CHECK(adsp_rms(b + n / 2, n / 2) < 0.01, "hpf time domain");
    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 5000, 1);
    adsp_biquad_reset(&bq);
    adsp_biquad_process(&bq, b, n);
    CHECK(NEAR(adsp_rms(b + n / 2, n / 2), 0.7071, 0.05), "hpf passes");

    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 60, 0.5f);
    adsp_bass_treble(b, n, FS, 6, 0);
    CHECK(adsp_rms(b + n / 2, n / 2) > 0.5f * 0.7071f * 1.8f, "bass boost");
    free(b);
}

static void test_dynamics(void) {
    size_t n = 44100;
    float *b = alloc_f(n);
    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 440, 1.0f);
    adsp_limit(b, n, FS, -6.0f, 50);
    CHECK(adsp_peak(b, n) <= powf(10, -6 / 20.0f) + 1e-6, "limiter ceiling %f", adsp_peak(b, n));
    CHECK(adsp_peak(b, n) > powf(10, -6 / 20.0f) * 0.9, "limiter not over-attenuating");

    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 440, 1.0f);
    adsp_compressor_params p = {-20, 4, 1, 100, 0, 0};
    adsp_compress(b, n, FS, &p);
    float pk = adsp_peak(b + n / 2, n / 2);
    CHECK(pk < 0.5f && pk > 0.05f, "compressor reduces peak %f", pk);

    /* Gate: quiet noise floor should be attenuated, loud tone kept. */
    for (size_t i = 0; i < n; i++) b[i] = (i < n / 2) ? 0.001f * ((i & 1) ? 1 : -1) : 0.0f;
    adsp_generate_tone(b + n / 2, n / 2, FS, ADSP_WAVE_SINE, 440, 0.5f);
    adsp_noise_gate(b, n, FS, -40, 24, 1, 50, 50);
    CHECK(adsp_peak(b + n / 4, n / 4) < 0.0002f, "gate closes");
    CHECK(adsp_peak(b + 3 * n / 4, n / 4) > 0.45f, "gate open");
    free(b);
}

static void test_fft_spectral(void) {
    size_t N = 1024;
    float re[1024], im[1024];
    for (size_t i = 0; i < N; i++) { re[i] = (float)sin(2 * M_PI * 8 * i / N); im[i] = 0; }
    CHECK(adsp_fft(re, im, N, 0) == 0, "fft ok");
    CHECK(NEAR(sqrt(re[8] * re[8] + im[8] * im[8]), N / 2.0, 1e-2), "fft bin 8");
    CHECK(NEAR(re[3], 0, 1e-3), "fft leakage");
    adsp_fft(re, im, N, 1);
    CHECK(NEAR(re[N / 4], sin(2 * M_PI * 8 * (N / 4) / N), 1e-4), "ifft roundtrip");
    CHECK(adsp_fft(re, im, 1000, 0) != 0, "fft rejects non pow2");

    size_t n = 44100;
    float *b = alloc_f(n), *noise = alloc_f(n);
    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 1000, 1.0f);
    float *db = alloc_f(2049);
    adsp_spectrum_db(b, n, 4096, db);
    size_t bin = (size_t)llround(1000.0 / FS * 4096);
    CHECK(db[bin] > -8 && db[bin] < 1, "spectrum peak %f", db[bin]);
    CHECK(db[1500] < -60, "spectrum floor %f", db[1500]);

    /* Noise reduction: noise-only section should drop, tone section preserved. */
    adsp_generate_noise(noise, n, ADSP_NOISE_WHITE, 0.02f, 7);
    float *prof = alloc_f(2049);
    adsp_noise_profile(noise, n, 2048, prof);
    for (size_t i = 0; i < n; i++) b[i] = noise[(i * 7919) % n];
    adsp_generate_tone(noise, n / 2, FS, ADSP_WAVE_SINE, 1000, 0.5f);
    for (size_t i = n / 2; i < n; i++) b[i] += noise[i - n / 2];
    float before = adsp_rms(b + 2048, n / 2 - 4096);
    adsp_noise_reduce(b, n, 2048, prof, 18, 3.0f, 2);
    float after = adsp_rms(b + 2048, n / 2 - 4096);
    CHECK(after < before * 0.25f, "noise reduced %f -> %f", before, after);
    float tone = adsp_rms(b + n / 2 + 4096, n / 2 - 8192);
    CHECK(NEAR(tone, 0.5 * 0.7071, 0.03), "tone kept %f", tone);
    free(b); free(noise); free(db); free(prof);
}

static void test_time(void) {
    size_t n = 44100;
    float *b = alloc_f(n);
    adsp_generate_tone(b, n, FS, ADSP_WAVE_SINE, 440, 0.8f);

    size_t m = adsp_resample_length(n, 2.0);
    float *o = alloc_f(m + 10);
    CHECK(adsp_resample(b, n, 2.0, o, m) == m && m == n / 2, "resample len");
    CHECK(NEAR(zc_freq(o, m, FS), 880, 5), "resample doubles pitch %f", zc_freq(o, m, FS));
    free(o);

    m = adsp_resample_length(n, 0.5);
    o = alloc_f(m);
    adsp_resample(b, n, 0.5, o, m);
    CHECK(NEAR(zc_freq(o, m, FS), 220, 3), "resample halves pitch");
    CHECK(NEAR(adsp_rms(o + 1000, m - 2000), 0.8 * 0.7071, 0.01), "resample keeps level");
    free(o);

    m = adsp_time_stretch_length(n, 1.5);
    o = alloc_f(m);
    CHECK(adsp_time_stretch(b, n, 1.5, (int)FS, o, m) == m && m == 29400, "stretch len %zu", m);
    CHECK(NEAR(zc_freq(o + 2000, m - 4000, FS), 440, 6), "stretch keeps pitch %f", zc_freq(o + 2000, m - 4000, FS));
    CHECK(NEAR(adsp_rms(o + 2000, m - 4000), 0.8 * 0.7071, 0.06), "stretch keeps level %f", adsp_rms(o + 2000, m - 4000));
    free(o);

    o = alloc_f(n);
    adsp_pitch_shift(b, n, 12.0, (int)FS, o);
    CHECK(NEAR(zc_freq(o + 2000, n - 4000, FS), 880, 10), "pitch +12 %f", zc_freq(o + 2000, n - 4000, FS));
    free(o);
    free(b);
}

static void test_generators(void) {
    size_t n = 44100;
    float *b = alloc_f(n);
    adsp_generate_tone(b, n, FS, ADSP_WAVE_SQUARE, 100, 0.5f);
    CHECK(NEAR(adsp_rms(b, n), 0.5, 1e-3), "square rms");
    adsp_generate_tone(b, n, FS, ADSP_WAVE_TRIANGLE, 100, 1);
    CHECK(NEAR(adsp_rms(b, n), 1 / sqrt(3), 1e-2), "triangle rms");
    adsp_generate_noise(b, n, ADSP_NOISE_WHITE, 1, 1);
    CHECK(NEAR(adsp_rms(b, n), 1 / sqrt(3), 0.02) && NEAR(adsp_mean(b, n), 0, 0.02), "white noise");
    adsp_generate_noise(b, n, ADSP_NOISE_PINK, 1, 1);
    CHECK(adsp_peak(b, n) <= 1.0f && adsp_rms(b, n) > 0.05, "pink noise");
    CHECK(adsp_generate_dtmf(b, 4410, FS, '5', 1) == 0, "dtmf ok");
    CHECK(adsp_generate_dtmf(b, 4410, FS, 'x', 1) != 0, "dtmf invalid");
    free(b);
}

static void test_wav(void) {
    size_t frames = 1000;
    float *l = alloc_f(frames), *r = alloc_f(frames);
    adsp_generate_tone(l, frames, FS, ADSP_WAVE_SINE, 440, 0.9f);
    adsp_generate_tone(r, frames, FS, ADSP_WAVE_SAWTOOTH, 220, 0.5f);
    const float *in[2] = {l, r};
    int formats[4][2] = {{16, 0}, {24, 0}, {32, 0}, {32, 1}};
    double tol[4] = {1.0 / 16000, 1.0 / 4000000, 1e-8, 0};
    for (int f = 0; f < 4; f++) {
        size_t cap = adsp_wav_encoded_size(2, frames, formats[f][0]);
        uint8_t *bytes = malloc(cap);
        size_t w = adsp_wav_encode(in, 2, frames, 44100, formats[f][0], formats[f][1], bytes, cap);
        CHECK(w == cap, "wav encode size");
        adsp_wav_info info;
        size_t off = adsp_wav_parse(bytes, w, &info);
        CHECK(off == 44 && info.channels == 2 && info.sample_rate == 44100 && info.frames == frames &&
              info.is_float == formats[f][1], "wav parse %d", f);
        float *ol = alloc_f(frames), *orr = alloc_f(frames);
        float *outs[2] = {ol, orr};
        CHECK(adsp_wav_decode(bytes, w, &info, off, outs) == 0, "wav decode");
        double maxerr = 0;
        for (size_t i = 0; i < frames; i++) {
            double e1 = fabs(ol[i] - l[i]), e2 = fabs(orr[i] - r[i]);
            if (e1 > maxerr) maxerr = e1;
            if (e2 > maxerr) maxerr = e2;
        }
        CHECK(maxerr <= tol[f] + 1e-9, "wav roundtrip %d err %g", f, maxerr);
        free(bytes); free(ol); free(orr);
    }
    uint8_t junk[16] = "RIFFxxxxWAVE";
    adsp_wav_info info;
    CHECK(adsp_wav_parse(junk, sizeof junk, &info) == 0, "wav rejects missing chunks");
    free(l); free(r);
}

int main(void) {
    test_analysis();
    test_basic();
    test_filters();
    test_dynamics();
    test_fft_spectral();
    test_time();
    test_generators();
    test_wav();
    printf("%d/%d checks passed\n", checks - failures, checks);
    return failures ? 1 : 0;
}
