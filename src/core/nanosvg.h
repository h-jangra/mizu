#ifndef NANOSVG_H
#define NANOSVG_H

/* NanoSVG - a simple stupid single-header-file SVG parser.
 *
 * The output of the parser is a list of cubic bezier shapes.
 * The library suits well for rendering scalable icons in applications.
 *
 * The shapes are transformed by the viewBox and converted to the requested
 * units. NanoSVG returns paths in pixels (or other units) at the given DPI.
 *
 * zlib license - see nanosvg_rasterizer.h for full text attribution.
 *
 * API:
 *   NSVGimage* image = nsvgParseFromFile("icon.svg", "px", 96);
 *   for each shape -> for each path -> draw cubic beziers
 *   nsvgDelete(image);
 */

#ifndef NANOSVG_CPLUSPLUS
#  ifdef __cplusplus
extern "C" {
#  endif
#endif

enum NSVGpaintType {
	NSVG_PAINT_UNDEF = -1,
	NSVG_PAINT_NONE = 0,
	NSVG_PAINT_COLOR = 1,
	NSVG_PAINT_LINEAR_GRADIENT = 2,
	NSVG_PAINT_RADIAL_GRADIENT = 3
};

enum NSVGspreadType {
	NSVG_SPREAD_PAD = 0,
	NSVG_SPREAD_REFLECT = 1,
	NSVG_SPREAD_REPEAT = 2
};

enum NSVGlineJoin {
	NSVG_JOIN_MITER = 0,
	NSVG_JOIN_ROUND = 1,
	NSVG_JOIN_BEVEL = 2
};

enum NSVGlineCap {
	NSVG_CAP_BUTT = 0,
	NSVG_CAP_ROUND = 1,
	NSVG_CAP_SQUARE = 2
};

enum NSVGfillRule {
	NSVG_FILLRULE_NONZERO = 0,
	NSVG_FILLRULE_EVENODD = 1
};

enum NSVGflags {
	NSVG_FLAGS_VISIBLE = 0x01
};

typedef struct NSVGgradientStop {
	unsigned int color;
	float offset;
} NSVGgradientStop;

typedef struct NSVGgradient {
	float xform[6];
	char spread;
	float fx, fy;
	int nstops;
	NSVGgradientStop* stops;
} NSVGgradient;

typedef struct NSVGpaint {
	signed char type;
	union {
		unsigned int color;
		NSVGgradient* gradient;
	};
} NSVGpaint;

typedef struct NSVGpath {
	float* pts;               /* Cubic bezier points: x0,y0, [cpx1,cpy1,cpx2,cpy2,x1,y1], ... */
	int npts;                 /* Total number of points */
	char closed;              /* Flag indicating if shape should be treated as closed */
	float bounds[4];          /* Tight bounding box [minx,miny,maxx,maxy] */
	struct NSVGpath* next;    /* Pointer to next path, or NULL */
} NSVGpath;

typedef struct NSVGshape {
	NSVGpaint fill;
	NSVGpaint stroke;
	float opacity;
	float strokeWidth;
	float strokeDashOffset;
	float strokeDashArray[8];
	char strokeDashCount;
	char strokeLineJoin;
	char strokeLineCap;
	char fillRule;
	unsigned char paintOrder;
	unsigned char flags;
	float bounds[4];
	float xform[6];
	NSVGpath* paths;
	struct NSVGshape* next;   /* Pointer to next shape, or NULL */
} NSVGshape;

typedef struct NSVGimage {
	float width;
	float height;
	NSVGshape* shapes;
} NSVGimage;

/* Parse SVG file from disk. Returns NULL on failure. units: "px","pt","pc","mm","cm","in". */
NSVGimage* nsvgParseFromFile(const char* filename, const char* units, float dpi);
/* Parse SVG from a null-terminated string in memory. */
NSVGimage* nsvgParse(char* input, const char* units, float dpi);
/* Free an image returned by nsvgParse* . */
void nsvgDelete(NSVGimage* image);

#ifndef NANOSVG_CPLUSPLUS
#  ifdef __cplusplus
}
#  endif
#endif

#endif /* NANOSVG_H */
