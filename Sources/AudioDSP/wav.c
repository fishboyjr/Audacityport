/* RIFF/WAVE reader and writer (PCM 8/16/24/32, IEEE float 32/64, WAVE_FORMAT_EXTENSIBLE). */
#include "AudioDSP.h"
#include "dsp_internal.h"
#include <math.h>
#include <string.h>

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

size_t adsp_wav_parse(const uint8_t *d, size_t len, adsp_wav_info *info) {
    if (len < 12 || memcmp(d, "RIFF", 4) != 0 || memcmp(d + 8, "WAVE", 4) != 0) return 0;
    size_t pos = 12;
    int have_fmt = 0;
    memset(info, 0, sizeof(*info));
    while (pos + 8 <= len) {
        uint32_t sz = rd32(d + pos + 4);
        const uint8_t *body = d + pos + 8;
        if (memcmp(d + pos, "fmt ", 4) == 0) {
            if (sz < 16 || pos + 8 + sz > len) return 0;
            uint16_t fmt = rd16(body);
            info->channels = rd16(body + 2);
            info->sample_rate = (int)rd32(body + 4);
            info->bits_per_sample = rd16(body + 14);
            if (fmt == 0xFFFE && sz >= 40) fmt = rd16(body + 24); /* sub-format GUID */
            if (fmt == 1) info->is_float = 0;
            else if (fmt == 3) info->is_float = 1;
            else return 0;
            have_fmt = 1;
        } else if (memcmp(d + pos, "data", 4) == 0) {
            if (!have_fmt || info->channels <= 0 || info->bits_per_sample <= 0) return 0;
            size_t avail = len - (pos + 8);
            size_t bytes = sz;
            if (bytes > avail || sz == 0xFFFFFFFFu) bytes = avail; /* tolerate streamed headers */
            size_t frame_bytes = (size_t)info->channels * (size_t)(info->bits_per_sample / 8);
            if (frame_bytes == 0) return 0;
            info->frames = bytes / frame_bytes;
            return pos + 8;
        }
        pos += 8 + sz + (sz & 1);
    }
    return 0;
}

int adsp_wav_decode(const uint8_t *d, size_t len, const adsp_wav_info *info, size_t off, float **out) {
    int ch = info->channels, bps = info->bits_per_sample / 8;
    if (off + info->frames * (size_t)ch * (size_t)bps > len) return -1;
    const uint8_t *p = d + off;
    for (size_t f = 0; f < info->frames; f++) {
        for (int c = 0; c < ch; c++, p += bps) {
            float v;
            if (info->is_float) {
                if (bps == 4) { uint32_t u = rd32(p); memcpy(&v, &u, 4); }
                else if (bps == 8) {
                    uint64_t u = (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
                    double dv; memcpy(&dv, &u, 8); v = (float)dv;
                } else return -2;
            } else {
                switch (bps) {
                case 1: v = ((int)p[0] - 128) / 128.0f; break;
                case 2: v = (int16_t)rd16(p) / 32768.0f; break;
                case 3: {
                    int32_t s = (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8;
                    v = s / 8388608.0f;
                    break;
                }
                case 4: v = (float)((int32_t)rd32(p) / 2147483648.0); break;
                default: return -2;
                }
            }
            out[c][f] = v;
        }
    }
    return 0;
}

size_t adsp_wav_encoded_size(int channels, size_t frames, int bits) {
    return 44 + (size_t)channels * frames * (size_t)(bits / 8);
}

static inline uint32_t lcg(uint32_t *s) { return *s = *s * 1664525u + 1013904223u; }

size_t adsp_wav_encode(const float *const *in, int ch, size_t frames, int sr, int bits, int is_float,
                       uint8_t *out, size_t cap) {
    if (is_float) bits = 32;
    if (!(bits == 16 || bits == 24 || bits == 32) || ch <= 0) return 0;
    size_t total = adsp_wav_encoded_size(ch, frames, bits);
    if (total > cap) return 0;
    size_t data = total - 44;
    int bps = bits / 8;
    memcpy(out, "RIFF", 4); wr32(out + 4, (uint32_t)(total - 8));
    memcpy(out + 8, "WAVE", 4);
    memcpy(out + 12, "fmt ", 4); wr32(out + 16, 16);
    wr16(out + 20, is_float ? 3 : 1);
    wr16(out + 22, (uint16_t)ch);
    wr32(out + 24, (uint32_t)sr);
    wr32(out + 28, (uint32_t)(sr * ch * bps));
    wr16(out + 32, (uint16_t)(ch * bps));
    wr16(out + 34, (uint16_t)bits);
    memcpy(out + 36, "data", 4); wr32(out + 40, (uint32_t)data);

    uint8_t *p = out + 44;
    uint32_t seed = 22222u;
    for (size_t f = 0; f < frames; f++) {
        for (int c = 0; c < ch; c++, p += bps) {
            float v = in[c][f];
            if (is_float) { uint32_t u; memcpy(&u, &v, 4); wr32(p, u); continue; }
            double scale = bits == 16 ? 32768.0 : bits == 24 ? 8388608.0 : 2147483648.0;
            double x = (double)v * scale;
            if (bits <= 24) {
                /* TPDF dither, +/- 1 LSB. */
                double r1 = lcg(&seed) / 4294967296.0, r2 = lcg(&seed) / 4294967296.0;
                x += r1 - r2;
            }
            x = floor(x + 0.5);
            if (x > scale - 1) x = scale - 1;
            if (x < -scale) x = -scale;
            int32_t s = (int32_t)x;
            if (bits == 16) wr16(p, (uint16_t)(int16_t)s);
            else if (bits == 24) { p[0] = (uint8_t)s; p[1] = (uint8_t)(s >> 8); p[2] = (uint8_t)(s >> 16); }
            else wr32(p, (uint32_t)s);
        }
    }
    return total;
}
