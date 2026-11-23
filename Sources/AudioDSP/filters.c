/* RBJ biquad filters and Bass & Treble. */
#include "AudioDSP.h"
#include "dsp_internal.h"
#include <math.h>

void adsp_biquad_reset(adsp_biquad *bq) { bq->z1 = bq->z2 = 0.0; }

void adsp_biquad_design(adsp_biquad *bq, adsp_biquad_type type, double fs,
                        double f, double q, double gain_db) {
    if (q <= 0) q = 0.7071067811865476;
    if (f <= 0) f = 1;
    if (f >= fs * 0.5) f = fs * 0.499;
    double A = pow(10.0, gain_db / 40.0);
    double w0 = 2.0 * M_PI * f / fs;
    double cw = cos(w0), sw = sin(w0);
    double alpha = sw / (2.0 * q);
    double sq = 2.0 * sqrt(A) * alpha;
    double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;

    switch (type) {
    case ADSP_BQ_LOWPASS:
        b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    case ADSP_BQ_HIGHPASS:
        b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    case ADSP_BQ_BANDPASS:
        b0 = alpha; b1 = 0; b2 = -alpha;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    case ADSP_BQ_NOTCH:
        b0 = 1; b1 = -2 * cw; b2 = 1;
        a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
        break;
    case ADSP_BQ_PEAK:
        b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A;
        a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
        break;
    case ADSP_BQ_LOWSHELF:
        b0 = A * ((A + 1) - (A - 1) * cw + sq);
        b1 = 2 * A * ((A - 1) - (A + 1) * cw);
        b2 = A * ((A + 1) - (A - 1) * cw - sq);
        a0 = (A + 1) + (A - 1) * cw + sq;
        a1 = -2 * ((A - 1) + (A + 1) * cw);
        a2 = (A + 1) + (A - 1) * cw - sq;
        break;
    case ADSP_BQ_HIGHSHELF:
        b0 = A * ((A + 1) + (A - 1) * cw + sq);
        b1 = -2 * A * ((A - 1) + (A + 1) * cw);
        b2 = A * ((A + 1) + (A - 1) * cw - sq);
        a0 = (A + 1) - (A - 1) * cw + sq;
        a1 = 2 * ((A - 1) - (A + 1) * cw);
        a2 = (A + 1) - (A - 1) * cw - sq;
        break;
    }
    bq->b0 = b0 / a0; bq->b1 = b1 / a0; bq->b2 = b2 / a0;
    bq->a1 = a1 / a0; bq->a2 = a2 / a0;
    adsp_biquad_reset(bq);
}

void adsp_biquad_process(adsp_biquad *bq, float *buf, size_t n) {
    double z1 = bq->z1, z2 = bq->z2;
    const double b0 = bq->b0, b1 = bq->b1, b2 = bq->b2, a1 = bq->a1, a2 = bq->a2;
    for (size_t i = 0; i < n; i++) {
        double x = buf[i];
        double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        buf[i] = (float)y;
    }
    /* Flush denormals. */
    if (fabs(z1) < 1e-30) z1 = 0;
    if (fabs(z2) < 1e-30) z2 = 0;
    bq->z1 = z1; bq->z2 = z2;
}

double adsp_biquad_response_db(const adsp_biquad *bq, double fs, double f) {
    double w = 2.0 * M_PI * f / fs;
    double c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    double nr = bq->b0 + bq->b1 * c1 + bq->b2 * c2;
    double ni = -(bq->b1 * s1 + bq->b2 * s2);
    double dr = 1.0 + bq->a1 * c1 + bq->a2 * c2;
    double di = -(bq->a1 * s1 + bq->a2 * s2);
    double mag2 = (nr * nr + ni * ni) / (dr * dr + di * di);
    if (mag2 <= 1e-30) return -300.0;
    return 10.0 * log10(mag2);
}

void adsp_bass_treble(float *buf, size_t n, double fs, double bass_db, double treble_db) {
    adsp_biquad bq;
    if (fabs(bass_db) > 1e-6) {
        adsp_biquad_design(&bq, ADSP_BQ_LOWSHELF, fs, 250.0, 0.7071067811865476, bass_db);
        adsp_biquad_process(&bq, buf, n);
    }
    if (fabs(treble_db) > 1e-6) {
        adsp_biquad_design(&bq, ADSP_BQ_HIGHSHELF, fs, 4000.0, 0.7071067811865476, treble_db);
        adsp_biquad_process(&bq, buf, n);
    }
}
