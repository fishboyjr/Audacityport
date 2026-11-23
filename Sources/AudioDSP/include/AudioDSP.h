/*
 * AudioDSP — portable C signal-processing core for the iOS port.
 *
 * All buffers are mono, 32-bit float, nominal range [-1, 1].
 * Multichannel tracks are processed channel by channel by the Swift layer.
 * Every function is pure (no global state, no allocation unless documented)
 * so the core can be unit tested on any platform and called from Swift.
 */
#ifndef AUDIODSP_H
#define AUDIODSP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------- Analysis ---------- */

/** Peak absolute sample value. */
float adsp_peak(const float *buf, size_t n);

/** Root-mean-square level. */
float adsp_rms(const float *buf, size_t n);

/** Mean (DC offset). */
float adsp_mean(const float *buf, size_t n);

/**
 * Waveform summary for drawing: for each of `columns` bins write
 * min, max and rms of the samples in [start, start+count).
 * Output arrays must hold `columns` floats each.
 */
void adsp_summarize(const float *buf, size_t start, size_t count, size_t columns,
                    float *out_min, float *out_max, float *out_rms);

/* ---------- Basic effects (in place) ---------- */

/** Multiply by linear gain. */
void adsp_gain(float *buf, size_t n, float gain);

/** Linear gain needed so peak hits `target_db` dBFS (returns 1 for silence). */
float adsp_normalize_gain(const float *buf, size_t n, float target_db);

/** Remove DC offset then scale peak to target_db. */
void adsp_normalize(float *buf, size_t n, float target_db, int remove_dc);

typedef enum {
    ADSP_FADE_LINEAR = 0,
    ADSP_FADE_EXPONENTIAL = 1, /* perceptually even (squared) */
    ADSP_FADE_LOGARITHMIC = 2, /* fast start (sqrt) */
    ADSP_FADE_SCURVE = 3       /* raised cosine */
} adsp_fade_curve;

/** Fade from gain 0 to 1 across the buffer. */
void adsp_fade_in(float *buf, size_t n, adsp_fade_curve curve);

/** Fade from gain 1 to 0 across the buffer. */
void adsp_fade_out(float *buf, size_t n, adsp_fade_curve curve);

void adsp_reverse(float *buf, size_t n);
void adsp_invert(float *buf, size_t n);
void adsp_silence(float *buf, size_t n);
void adsp_remove_dc(float *buf, size_t n);

/** Hard clip to +/- limit. Returns number of samples clipped. */
size_t adsp_hard_clip(float *buf, size_t n, float limit);

/* ---------- Time-based effects ---------- */

/**
 * Echo / delay with feedback. delay_samples > 0, decay in [0, 1).
 * In place; the tail beyond n is truncated (Swift layer may pad first).
 */
void adsp_echo(float *buf, size_t n, size_t delay_samples, float decay);

/**
 * Change speed (pitch and tempo together) by resampling.
 * Writes up to out_cap samples to out; returns samples written.
 * Output length is round(n / speed). speed > 0. Uses windowed-sinc
 * interpolation (Lanczos, a=8) for quality comparable to desktop editors.
 */
size_t adsp_resample(const float *in, size_t n, double speed, float *out, size_t out_cap);

/** Expected output length of adsp_resample. */
size_t adsp_resample_length(size_t n, double speed);

/**
 * Change tempo without changing pitch (WSOLA time stretch).
 * tempo > 1 is faster/shorter. Returns samples written to out.
 */
size_t adsp_time_stretch(const float *in, size_t n, double tempo, int sample_rate,
                         float *out, size_t out_cap);
size_t adsp_time_stretch_length(size_t n, double tempo);

/**
 * Change pitch without changing tempo, in semitones.
 * Implemented as time stretch followed by resample. out must hold n samples.
 * Returns samples written (== n).
 */
size_t adsp_pitch_shift(const float *in, size_t n, double semitones, int sample_rate, float *out);

/* ---------- Filters ---------- */

typedef enum {
    ADSP_BQ_LOWPASS = 0,
    ADSP_BQ_HIGHPASS,
    ADSP_BQ_BANDPASS,
    ADSP_BQ_NOTCH,
    ADSP_BQ_PEAK,
    ADSP_BQ_LOWSHELF,
    ADSP_BQ_HIGHSHELF
} adsp_biquad_type;

typedef struct {
    double b0, b1, b2, a1, a2; /* normalised so a0 == 1 */
    double z1, z2;             /* transposed direct form II state */
} adsp_biquad;

/** RBJ cookbook design. gain_db used by peak/shelf types. */
void adsp_biquad_design(adsp_biquad *bq, adsp_biquad_type type, double sample_rate,
                        double freq, double q, double gain_db);
void adsp_biquad_reset(adsp_biquad *bq);
void adsp_biquad_process(adsp_biquad *bq, float *buf, size_t n);

/** Magnitude response in dB at freq (for drawing EQ curves). */
double adsp_biquad_response_db(const adsp_biquad *bq, double sample_rate, double freq);

/** Bass & treble shelving (like the desktop "Bass and Treble" effect). */
void adsp_bass_treble(float *buf, size_t n, double sample_rate, double bass_db, double treble_db);

/* ---------- Dynamics ---------- */

typedef struct {
    float threshold_db; /* e.g. -12 */
    float ratio;        /* e.g. 2..20 */
    float attack_ms;    /* e.g. 0.2 */
    float release_ms;   /* e.g. 100 */
    float makeup_db;    /* additional output gain */
    int   auto_makeup;  /* normalise to 0 dB after compression */
} adsp_compressor_params;

void adsp_compress(float *buf, size_t n, double sample_rate, const adsp_compressor_params *p);

/** Noise gate: attenuate by `reduction_db` while envelope is below threshold. */
void adsp_noise_gate(float *buf, size_t n, double sample_rate, float threshold_db,
                     float reduction_db, float attack_ms, float hold_ms, float release_ms);

/** Look-ahead brickwall limiter. */
void adsp_limit(float *buf, size_t n, double sample_rate, float ceiling_db, float release_ms);

/* ---------- Spectral ---------- */

/** In-place radix-2 complex FFT. n must be a power of two. inverse != 0 for IFFT (scaled 1/n). */
int adsp_fft(float *re, float *im, size_t n, int inverse);

/**
 * Noise profile: average magnitude spectrum (fft_size/2+1 bins) of `noise`.
 * Returns 0 on success.
 */
int adsp_noise_profile(const float *noise, size_t n, size_t fft_size, float *out_profile);

/**
 * Spectral-subtraction noise reduction using a profile from adsp_noise_profile.
 * reduction_db: how much to attenuate noise (e.g. 12).
 * sensitivity: multiplier on the profile threshold (e.g. 1.5..6).
 * smoothing_bands: frequency smoothing of the gain mask (0..6).
 * Processes in place with 75% overlap Hann windows. Returns 0 on success.
 */
int adsp_noise_reduce(float *buf, size_t n, size_t fft_size, const float *profile,
                      float reduction_db, float sensitivity, int smoothing_bands);

/** Magnitude spectrum in dB (fft_size/2+1 bins), Hann windowed, averaged over buffer. */
int adsp_spectrum_db(const float *buf, size_t n, size_t fft_size, float *out_db);

/* ---------- Generators ---------- */

typedef enum {
    ADSP_WAVE_SINE = 0,
    ADSP_WAVE_SQUARE,
    ADSP_WAVE_SAWTOOTH,
    ADSP_WAVE_TRIANGLE
} adsp_waveform;

void adsp_generate_tone(float *buf, size_t n, double sample_rate, adsp_waveform wave,
                        double freq, float amplitude);

typedef enum { ADSP_NOISE_WHITE = 0, ADSP_NOISE_PINK, ADSP_NOISE_BROWN } adsp_noise_type;

void adsp_generate_noise(float *buf, size_t n, adsp_noise_type type, float amplitude, uint32_t seed);

/** DTMF tone for one key ('0'-'9','*','#','A'-'D'). Returns 0 on success. */
int adsp_generate_dtmf(float *buf, size_t n, double sample_rate, char key, float amplitude);

/* ---------- Mixing ---------- */

/** dst += src * gain, with constant-power pan applied for channel `ch` (0=L,1=R) of `channels`. */
void adsp_mix_into(float *dst, const float *src, size_t n, float gain, float pan, int ch, int channels);

/* ---------- WAV I/O (PCM16/24/32, float32) ---------- */

typedef struct {
    int    channels;
    int    sample_rate;
    int    bits_per_sample;
    int    is_float;
    size_t frames;
} adsp_wav_info;

/** Parse header from memory. Returns offset of sample data, or 0 on error. */
size_t adsp_wav_parse(const uint8_t *data, size_t len, adsp_wav_info *info);

/** Decode interleaved samples to planar float. out[ch] must hold info->frames floats. */
int adsp_wav_decode(const uint8_t *data, size_t len, const adsp_wav_info *info, size_t offset,
                    float **out);

/** Bytes needed for adsp_wav_encode. */
size_t adsp_wav_encoded_size(int channels, size_t frames, int bits_per_sample);

/** Encode planar float to a complete WAV file (TPDF-dithered when bits <= 24). Returns bytes written. */
size_t adsp_wav_encode(const float *const *in, int channels, size_t frames, int sample_rate,
                       int bits_per_sample, int is_float, uint8_t *out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* AUDIODSP_H */
