#include "PhotoDecoder.h"
#include <vips/vips.h>
#include <string.h>

static gsize initialized = 0;

int marketplace_decode_photo(const void *input, size_t length,
                             void **output, size_t *output_length, int *format) {
    if (g_once_init_enter(&initialized)) {
        int ok = vips_init("ku-marketplace") == 0;
        if (ok) {
            /* Do not cache lazy images backed by Swift's temporary input buffer. */
            vips_cache_set_max(0);
            vips_concurrency_set(1);
        }
        g_once_init_leave(&initialized, ok ? 1 : 2);
    }
    if (initialized != 1) return 3;
    *output = NULL;
    *output_length = 0;
    const unsigned char *bytes = input;
    VipsImage *image = NULL;
    VipsImage *oriented = NULL;
    int status = -1;
    int is_png = length >= 8 && memcmp(bytes, "\x89PNG\r\n\x1a\n", 8) == 0;
    int is_jpeg = length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
    int is_heic = length >= 12 && memcmp(bytes + 4, "ftyp", 4) == 0 &&
        (memcmp(bytes + 8, "heic", 4) == 0 || memcmp(bytes + 8, "heix", 4) == 0 ||
         memcmp(bytes + 8, "mif1", 4) == 0 || memcmp(bytes + 8, "msf1", 4) == 0);
    if (is_png) {
        status = vips_pngload_buffer((void *) input, length, &image,
            "access", VIPS_ACCESS_SEQUENTIAL, "fail_on", VIPS_FAIL_ON_WARNING, NULL);
    } else if (is_jpeg) {
        status = vips_jpegload_buffer((void *) input, length, &image,
            "access", VIPS_ACCESS_SEQUENTIAL, "fail_on", VIPS_FAIL_ON_WARNING, NULL);
    } else if (is_heic) {
        status = vips_heifload_buffer((void *) input, length, &image,
            "access", VIPS_ACCESS_SEQUENTIAL, "fail_on", VIPS_FAIL_ON_WARNING, NULL);
    }
    if (status != 0 || image == NULL) goto invalid;
    int width = vips_image_get_width(image);
    int height = vips_image_get_height(image);
    if (width <= 0 || height <= 0 || (long long) width * height > 20000000) {
        g_object_unref(image);
        vips_error_clear();
        return 2;
    }
    if (vips_autorot(image, &oriented, NULL) != 0) goto invalid;
    /* Encoding forces every pixel to decode. Header-only inspection is insufficient.
     * Strip embedded metadata and normalize HEIC to JPEG for mobile display. */
    if (is_png) {
        status = vips_pngsave_buffer(oriented, output, output_length, "strip", TRUE, NULL);
        *format = 1;
    } else {
        status = vips_jpegsave_buffer(oriented, output, output_length, "strip", TRUE, "Q", 90, NULL);
        *format = 2;
    }
    if (status != 0) goto invalid;
    g_object_unref(oriented);
    g_object_unref(image);
    return 0;

invalid:
    if (oriented != NULL) g_object_unref(oriented);
    if (image != NULL) g_object_unref(image);
    if (*output != NULL) g_free(*output);
    *output = NULL;
    *output_length = 0;
    vips_error_clear();
    return 1;
}

void marketplace_free_photo(void *output) { g_free(output); }
