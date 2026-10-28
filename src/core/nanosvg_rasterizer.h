#ifndef NANOSVG_RASTERIZER_H
#define NANOSVG_RASTERIZER_H

/* NanoSVG rasterizer implementation.
 *
 * Renders an NSVGimage (produced by nanosvg.h parser) into an 8-bit alpha
 * bitmap at a given scale, applying the viewBox transform. Intended for
 * crisp icon rendering: it preserves aspect ratio, supports transparent
 * backgrounds, and renders at the requested physical resolution so HiDPI
 * icons stay sharp.
 *
 * zlib license (same as nanosvg.h):
 *   Copyright (c) 2013-14 Mikko Mononen memon@inside.org
 *   See nanosvg.h for full license text.
 */

#ifndef NANOSVG_CPLUSPLUS
#  ifdef __cplusplus
extern "C" {
#  endif
#endif

#include "nanosvg.h"

/* Rasterizer options */
typedef struct NSVGrasterizerOpts {
	int flags;           /* reserved */
} NSVGrasterizerOpts;

/* Opaque rasterizer state */
typedef struct NSVGrasterizer NSVGrasterizer;

/* Create a rasterizer. Returns NULL on failure. */
NSVGrasterizer* nsvgCreateRasterizer(void);

/* Delete a rasterizer. */
void nsvgDeleteRasterizer(NSVGrasterizer* rast);

/*
 * Rasterize an image into a pre-allocated alpha buffer.
 *
 * dst      - pointer to alpha buffer (width * height bytes)
 * width    - buffer width in pixels
 * height   - buffer height in pixels
 * stride   - bytes per row (>= width)
 * image    - NSVGimage to render
 * dx, dy   - offset to place the image (in buffer pixels)
 * scale    - uniform scale factor applied to the SVG (in buffer px per SVG unit)
 *
 * The SVG is mapped to the buffer so that one SVG unit = `scale` buffer pixels,
 * honoring the viewBox if present. Only the fill of visible shapes is rendered
 * (solid colors, alpha-blended). The result is written as 8-bit alpha coverage
 * into dst, suitable for tinting with a foreground color.
 *
 * Returns 0 on success, non-zero on failure.
 */
int nsvgRasterize(NSVGrasterizer* rast,
                  unsigned char* dst, int width, int height, int stride,
                  NSVGimage* image, float dx, float dy, float scale);

/*
 * Rasterize an image into a pre-allocated 32-bit ARGB8888 buffer.
 *
 * dst           - pointer to 32-bit ARGB buffer (native Wayland ARGB8888)
 * width         - buffer width in pixels
 * height        - buffer height in pixels
 * stride_pixels - pixels per row (>= width)
 * image         - NSVGimage to render
 * dx, dy        - offset in buffer pixels
 * scale         - uniform scale factor applied to the SVG
 *
 * Renders full-color shapes with anti-aliased fills and strokes into dst.
 * Returns 0 on success, non-zero on failure.
 */
int nsvgRasterizeArgb(NSVGrasterizer* rast,
                      unsigned int* dst, int width, int height, int stride_pixels,
                      NSVGimage* image, float dx, float dy, float scale);

#ifndef NANOSVG_CPLUSPLUS
#  ifdef __cplusplus
}
#  endif
#endif

#endif /* NANOSVG_RASTERIZER_H */
