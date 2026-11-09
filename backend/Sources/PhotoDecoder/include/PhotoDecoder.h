#ifndef MARKETPLACE_PHOTO_DECODER_H
#define MARKETPLACE_PHOTO_DECODER_H
#include <stddef.h>

/* Returns 0 on success, 1 for invalid data, 2 for excessive dimensions,
 * and 3 if the decoder cannot initialize. Output is PNG (format 1) or JPEG (2). */
int marketplace_decode_photo(const void *input, size_t length,
                             void **output, size_t *output_length, int *format);
void marketplace_free_photo(void *output);
#endif
