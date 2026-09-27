// AES-128-CTR through CommonCrypto, as AESDecryptor uses it, over 10 MB — about
// a four-minute track at 320 kbps. Fastest of ten runs.
#include <CommonCrypto/CommonCryptor.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(void) {
    size_t n = 10 * 1024 * 1024;
    unsigned char *in = calloc(n, 1), *out = malloc(n), key[16] = {1}, iv[16] = {2};
    double best = 1e9;
    for (int run = 0; run < 10; run++) {
        CCCryptorRef cryptor;
        CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv, key, 16, NULL, 0, 0, 0, &cryptor);
        struct timespec a, b;
        size_t moved;
        clock_gettime(CLOCK_MONOTONIC, &a);
        CCCryptorUpdate(cryptor, in, n, out, n, &moved);
        clock_gettime(CLOCK_MONOTONIC, &b);
        CCCryptorRelease(cryptor);
        double t = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
        if (t < best) best = t;
    }
    printf("AES-128-CTR, 10 MB: %.2f ms = %.1f GB/s\n", best * 1000, n / best / 1e9);
}
