// Decodes an Ogg Vorbis file with the vendored libvorbisfile, five times, and
// reports the fastest run against the audio's duration. Built by run.sh once
// per set of compiler flags.
#include <stdio.h>
#include <time.h>
#include <vorbis/vorbisfile.h>

int main(int argc, char **argv) {
    double best = 1e9, audio = 0;
    for (int run = 0; run < 5; run++) {
        OggVorbis_File vf;
        if (ov_fopen(argv[1], &vf) != 0) {
            puts("open failed");
            return 1;
        }
        long rate = ov_info(&vf, -1)->rate, frames = 0, n;
        int bitstream;
        float **pcm;
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        while ((n = ov_read_float(&vf, &pcm, 2048, &bitstream)) > 0) frames += n;
        clock_gettime(CLOCK_MONOTONIC, &b);
        double t = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
        if (t < best) best = t;
        audio = (double)frames / rate;
        ov_clear(&vf);
    }
    printf("%6.1f ms for %.0f s of audio = %5.0fx real time, %.3f%% of one core\n",
           best * 1000, audio, audio / best, 100 * best / audio);
}
