#include <stdio.h>
#include <string.h>
#include <webp/encode.h>

int export_webp(const char* path, const unsigned char* rgba, int w, int h) {
    uint8_t* data = NULL;
    size_t size = WebPEncodeRGBA(rgba, w, h, w * 4, 95.0f, &data);
    if (size == 0 || !data) return -1;
    FILE* fp = fopen(path, "wb");
    if (!fp) {
        WebPFree(data);
        return -1;
    }
    fwrite(data, 1, size, fp);
    fclose(fp);
    WebPFree(data);
    return 0;
}
