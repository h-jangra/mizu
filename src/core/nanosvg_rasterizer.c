/* NanoSVG rasterizer implementation
 *
 * Renders an NSVGimage into an 8-bit alpha coverage bitmap. Filled paths use
 * an analytic horizontal scanline with 4x vertical supersampling; stroked
 * paths are sampled with 4x4 supersampling. Rendering is done at the requested
 * physical resolution so icons stay crisp on HiDPI displays.
 *
 * zlib license - see nanosvg.h for full text.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "nanosvg.h"
#include "nanosvg_rasterizer.h"

/* Vertical sub-samples per pixel for filled paths. */
#define NSVG_SS 4

typedef struct NSVGrasterizer {
	int unused;
} NSVGrasterizer;

/* ---- Small growable point buffer -------------------------------------- */

typedef struct {
	float* pts; /* x0,y0,x1,y1,... */
	int count;  /* number of floats */
	int cap;
} PointBuf;

typedef struct {
	PointBuf poly;
	int closed;
} SubPath;

typedef struct {
	SubPath* items;
	int count;
} SubPathList;

static int bufAppend(PointBuf* b, float x, float y)
{
	if (b->count + 2 > b->cap) {
		int ncap = (b->cap == 0) ? 128 : b->cap * 2;
		float* n = (float*)realloc(b->pts, sizeof(float) * (size_t)ncap);
		if (!n) return 0;
		b->pts = n;
		b->cap = ncap;
	}
	b->pts[b->count++] = x;
	b->pts[b->count++] = y;
	return 1;
}

static void bufFree(PointBuf* b)
{
	free(b->pts);
	b->pts = NULL;
	b->count = 0;
	b->cap = 0;
}

/* ---- Cubic bezier flattening ------------------------------------------ */

static void flattenCubic(PointBuf* out,
                         float x1, float y1,
                         float c1x, float c1y,
                         float c2x, float c2y,
                         float x2, float y2,
                         float tol,
                         int level)
{
	float d1x = c1x - x1, d1y = c1y - y1;
	float d2x = c2x - c1x, d2y = c2y - c1y;
	float d3x = x2 - c2x, d3y = y2 - c2y;
	float dist = fabsf(d1x) + fabsf(d1y) + fabsf(d2x) + fabsf(d2y) + fabsf(d3x) + fabsf(d3y);

	if (dist < tol || level >= 16) {
		bufAppend(out, x2, y2);
		return;
	}

	float mx1 = (x1 + c1x) * 0.5f;
	float my1 = (y1 + c1y) * 0.5f;
	float mx2 = (c1x + c2x) * 0.5f;
	float my2 = (c1y + c2y) * 0.5f;
	float mx3 = (c2x + x2) * 0.5f;
	float my3 = (c2y + y2) * 0.5f;

	float lm1x = (mx1 + mx2) * 0.5f;
	float lm1y = (my1 + my2) * 0.5f;
	float lm2x = (mx2 + mx3) * 0.5f;
	float lm2y = (my2 + my3) * 0.5f;

	float lastx = (lm1x + lm2x) * 0.5f;
	float lasty = (lm1y + lm2y) * 0.5f;

	flattenCubic(out, x1, y1, mx1, my1, lm1x, lm1y, lastx, lasty, tol, level + 1);
	flattenCubic(out, lastx, lasty, lm2x, lm2y, mx3, my3, x2, y2, tol, level + 1);
}

static void buildPolyline(NSVGpath* path, PointBuf* out, float tol)
{
	if (!path || path->npts < 2) return;

	const float* pts = path->pts;
	float px = pts[0];
	float py = pts[1];
	bufAppend(out, px, py);

	int i = 2;
	while (i + 5 < path->npts) {
		float c1x = pts[i + 0], c1y = pts[i + 1];
		float c2x = pts[i + 2], c2y = pts[i + 3];
		float ex = pts[i + 4], ey = pts[i + 5];
		flattenCubic(out, px, py, c1x, c1y, c2x, c2y, ex, ey, tol, 0);
		px = ex;
		py = ey;
		i += 6;
	}

	if (path->closed && out->count >= 2) {
		float fx = out->pts[0];
		float fy = out->pts[1];
		if (px != fx || py != fy) bufAppend(out, fx, fy);
	}
}

/* ---- Geometry helpers ------------------------------------------------- */

static float distToSegmentSq(float px, float py, float x1, float y1, float x2, float y2)
{
	float dx = x2 - x1;
	float dy = y2 - y1;
	float len_sq = dx * dx + dy * dy;
	float t = 0.0f;
	if (len_sq > 0.000001f) {
		t = ((px - x1) * dx + (py - y1) * dy) / len_sq;
		if (t < 0.0f) t = 0.0f;
		else if (t > 1.0f) t = 1.0f;
	}
	float qx = x1 + t * dx - px;
	float qy = y1 + t * dy - py;
	return qx * qx + qy * qy;
}

static int nearStroke(const float* pts, int npts, int closed, float x, float y, float half_width)
{
	float best = half_width * half_width;
	int count = npts / 2;
	int edges = closed ? count : count - 1;
	for (int i = 0; i < edges; i++) {
		int j = (i + 1) % count;
		float d = distToSegmentSq(x, y, pts[i * 2], pts[i * 2 + 1], pts[j * 2], pts[j * 2 + 1]);
		if (d <= best) return 1;
	}
	return 0;
}

typedef struct {
	float x;
	int dir;
} Crossing;

static int crossingCmp(const void* a, const void* b)
{
	float xa = ((const Crossing*)a)->x;
	float xb = ((const Crossing*)b)->x;
	if (xa < xb) return -1;
	if (xa > xb) return 1;
	return 0;
}

/* ---- Filled path rasterization ---------------------------------------- */

/* Add the horizontal coverage of the span [xa, xb] (SVG units) to `acc`. */
static void addSpan(float* acc, int width, float scale, float tx, float xa, float xb)
{
	float pa = xa * scale + tx;
	float pb = xb * scale + tx;
	if (pa < 0.0f) pa = 0.0f;
	if (pb > (float)width) pb = (float)width;
	if (pb <= pa) return;

	int ax = (int)floorf(pa);
	int bx = (int)ceilf(pb);
	if (ax < 0) ax = 0;
	if (bx > width) bx = width;
	for (int px = ax; px < bx; px++) {
		float l = (float)px > pa ? (float)px : pa;
		float r = (float)(px + 1) < pb ? (float)(px + 1) : pb;
		if (r > l) acc[px] += (r - l) / (float)NSVG_SS;
	}
}

/* Analytic horizontal coverage with vertical supersampling, evaluated across
 * all subpaths of a shape so holes (opposite winding / even-odd) work. */
static void fillShape(unsigned char* dst, int width, int height, int stride,
                      const SubPathList* subs, int evenodd,
                      float tx, float ty, float scale, float alpha,
                      int px0, int py0, int px1, int py1)
{
	int total_edges = 0;
	for (int s = 0; s < subs->count; s++) total_edges += subs->items[s].poly.count / 2;
	if (total_edges < 3) return;

	Crossing* cross = (Crossing*)malloc(sizeof(Crossing) * (size_t)(total_edges + 4));
	float* acc = (float*)calloc((size_t)width, sizeof(float));
	if (!cross || !acc) {
		free(cross);
		free(acc);
		return;
	}

	for (int py = py0; py < py1; py++) {
		memset(acc, 0, (size_t)width * sizeof(float));

		for (int sy = 0; sy < NSVG_SS; sy++) {
			int srow = py * NSVG_SS + sy;
			float fy = ((float)srow + 0.5f) / (float)NSVG_SS;
			float syv = (fy - ty) / scale;
			int nc = 0;

			for (int s = 0; s < subs->count; s++) {
				const float* pts = subs->items[s].poly.pts;
				int n = subs->items[s].poly.count / 2;
				for (int i = 0; i < n; i++) {
					int j = (i + 1) % n;
					float x1 = pts[i * 2 + 0], y1 = pts[i * 2 + 1];
					float x2 = pts[j * 2 + 0], y2 = pts[j * 2 + 1];
					if ((y1 <= syv && y2 > syv) || (y2 <= syv && y1 > syv)) {
						float t = (syv - y1) / (y2 - y1);
						cross[nc].x = x1 + t * (x2 - x1);
						cross[nc].dir = (y2 > y1) ? 1 : -1;
						nc++;
					}
				}
			}

			if (nc < 2) continue;
			qsort(cross, (size_t)nc, sizeof(Crossing), crossingCmp);

			if (evenodd) {
				for (int i = 0; i + 1 < nc; i += 2) {
					addSpan(acc, width, scale, tx, cross[i].x, cross[i + 1].x);
				}
			} else {
				int winding = 0;
				float span_start = 0.0f;
				int have_span = 0;
				for (int i = 0; i < nc; i++) {
					int prev = winding;
					winding += cross[i].dir;
					if (prev == 0 && winding != 0) {
						span_start = cross[i].x;
						have_span = 1;
					} else if (prev != 0 && winding == 0 && have_span) {
						addSpan(acc, width, scale, tx, span_start, cross[i].x);
						have_span = 0;
					}
				}
			}
		}

		unsigned char* row = dst + (size_t)py * (size_t)stride;
		for (int px = px0; px < px1; px++) {
			float cov = acc[px];
			if (cov <= 0.0f) continue;
			if (cov > 1.0f) cov = 1.0f;
			int c = (int)(cov * alpha * 255.0f + 0.5f);
			if (c > 255) c = 255;
			if ((unsigned char)c > row[px]) row[px] = (unsigned char)c;
		}
	}

	free(cross);
	free(acc);
}

/* ---- Stroked path rasterization --------------------------------------- */

static void strokePath(unsigned char* dst, int width, int height, int stride,
                       const PointBuf* poly, int closed,
                       float tx, float ty, float scale, float alpha, float half_width,
                       int px0, int py0, int px1, int py1)
{
	const float sub_step = 1.0f / (float)NSVG_SS;
	const int total = NSVG_SS * NSVG_SS;

	for (int py = py0; py < py1; py++) {
		unsigned char* row = dst + (size_t)py * (size_t)stride;
		for (int px = px0; px < px1; px++) {
			int hits = 0;
			for (int sy = 0; sy < NSVG_SS; sy++) {
				float fy = (float)py + (float)sy * sub_step + sub_step * 0.5f;
				float syv = (fy - ty) / scale;
				for (int sx = 0; sx < NSVG_SS; sx++) {
					float fx = (float)px + (float)sx * sub_step + sub_step * 0.5f;
					float sxv = (fx - tx) / scale;
					if (nearStroke(poly->pts, poly->count, closed, sxv, syv, half_width)) hits++;
				}
			}
			if (hits == 0) continue;
			float cov = (float)hits / (float)total * alpha;
			int c = (int)(cov * 255.0f + 0.5f);
			if (c > 255) c = 255;
			if ((unsigned char)c > row[px]) row[px] = (unsigned char)c;
		}
	}
}

NSVGrasterizer* nsvgCreateRasterizer(void)
{
	return (NSVGrasterizer*)calloc(1, sizeof(NSVGrasterizer));
}

void nsvgDeleteRasterizer(NSVGrasterizer* rast)
{
	free(rast);
}

static void boundsOfSubpaths(const SubPathList* subs, float pad, float* out)
{
	float minx = 1e30f, miny = 1e30f, maxx = -1e30f, maxy = -1e30f;
	for (int s = 0; s < subs->count; s++) {
		const PointBuf* b = &subs->items[s].poly;
		for (int i = 0; i + 1 < b->count; i += 2) {
			if (b->pts[i] < minx) minx = b->pts[i];
			if (b->pts[i] > maxx) maxx = b->pts[i];
			if (b->pts[i + 1] < miny) miny = b->pts[i + 1];
			if (b->pts[i + 1] > maxy) maxy = b->pts[i + 1];
		}
	}
	out[0] = minx - pad;
	out[1] = miny - pad;
	out[2] = maxx + pad;
	out[3] = maxy + pad;
}

int nsvgRasterize(NSVGrasterizer* rast,
                  unsigned char* dst, int width, int height, int stride,
                  NSVGimage* image, float dx, float dy, float scale)
{
	if (!rast || !dst || !image || width <= 0 || height <= 0 || stride < width || scale <= 0.0f)
		return -1;

	if (image->width <= 0.0f || image->height <= 0.0f) return -1;

	/* Aim for roughly a third of a device pixel of error. Tolerance is in SVG
	 * user units, so it must counteract the output scale. */
	float tol = 0.35f / scale;
	if (tol < 0.02f) tol = 0.02f;
	if (tol > 16.0f) tol = 16.0f;

	NSVGshape* shape = image->shapes;
	while (shape) {
		if (!(shape->flags & NSVG_FLAGS_VISIBLE)) { shape = shape->next; continue; }

		int npaths = 0;
		for (NSVGpath* p = shape->paths; p; p = p->next) npaths++;
		if (npaths == 0) { shape = shape->next; continue; }

		SubPathList subs;
		subs.count = npaths;
		subs.items = (SubPath*)calloc((size_t)npaths, sizeof(SubPath));
		if (!subs.items) { shape = shape->next; continue; }

		int idx = 0;
		for (NSVGpath* p = shape->paths; p; p = p->next, idx++) {
			buildPolyline(p, &subs.items[idx].poly, tol);
			subs.items[idx].closed = p->closed;
		}

		int fill_on = 0;
		float fill_alpha = 0.0f;
		if (shape->fill.type == NSVG_PAINT_COLOR) {
			fill_alpha = ((shape->fill.color >> 24) & 0xFF) / 255.0f * shape->opacity;
			fill_on = fill_alpha > 0.0f;
		}

		int stroke_on = 0;
		float stroke_alpha = 0.0f;
		float half_width = 0.0f;
		if (shape->stroke.type == NSVG_PAINT_COLOR && shape->strokeWidth > 0.0f) {
			stroke_alpha = ((shape->stroke.color >> 24) & 0xFF) / 255.0f * shape->opacity;
			stroke_on = stroke_alpha > 0.0f;
			half_width = shape->strokeWidth * 0.5f;
		}

		if (fill_on || stroke_on) {
			float bounds[4];
			boundsOfSubpaths(&subs, half_width + 0.5f, bounds);

			int px0 = (int)floorf(bounds[0] * scale + dx);
			int py0 = (int)floorf(bounds[1] * scale + dy);
			int px1 = (int)ceilf(bounds[2] * scale + dx);
			int py1 = (int)ceilf(bounds[3] * scale + dy);
			if (px0 < 0) px0 = 0;
			if (py0 < 0) py0 = 0;
			if (px1 > width) px1 = width;
			if (py1 > height) py1 = height;

			if (px0 < px1 && py0 < py1) {
				if (fill_on) {
					fillShape(dst, width, height, stride, &subs,
					          shape->fillRule == NSVG_FILLRULE_EVENODD,
					          dx, dy, scale, fill_alpha, px0, py0, px1, py1);
				}
				if (stroke_on) {
					for (int s = 0; s < subs.count; s++) {
						PointBuf* poly = &subs.items[s].poly;
						if (poly->count < 4) continue;
						strokePath(dst, width, height, stride, poly, subs.items[s].closed,
						           dx, dy, scale, stroke_alpha, half_width, px0, py0, px1, py1);
					}
				}
			}
		}

		for (int s = 0; s < subs.count; s++) bufFree(&subs.items[s].poly);
		free(subs.items);
		shape = shape->next;
	}

	return 0;
}

/* ---- 32-bit ARGB Vector Rasterization ---------------------------------- */

static void fillShapeArgb(unsigned int* dst, int width, int height, int stride_pixels,
                          const SubPathList* subs, int evenodd,
                          float tx, float ty, float scale,
                          unsigned int color, float opacity,
                          int px0, int py0, int px1, int py1)
{
	int total_edges = 0;
	for (int s = 0; s < subs->count; s++) total_edges += subs->items[s].poly.count / 2;
	if (total_edges < 3) return;

	Crossing* cross = (Crossing*)malloc(sizeof(Crossing) * (size_t)(total_edges + 4));
	float* acc = (float*)calloc((size_t)width, sizeof(float));
	if (!cross || !acc) {
		free(cross);
		free(acc);
		return;
	}

	const float fill_a = (((color >> 24) & 0xFF) / 255.0f) * opacity;
	const unsigned int sr = (color >> 16) & 0xFF;
	const unsigned int sg = (color >> 8) & 0xFF;
	const unsigned int sb = color & 0xFF;

	for (int py = py0; py < py1; py++) {
		memset(acc, 0, (size_t)width * sizeof(float));

		for (int sy = 0; sy < NSVG_SS; sy++) {
			int srow = py * NSVG_SS + sy;
			float fy = ((float)srow + 0.5f) / (float)NSVG_SS;
			float syv = (fy - ty) / scale;
			int nc = 0;

			for (int s = 0; s < subs->count; s++) {
				const float* pts = subs->items[s].poly.pts;
				int n = subs->items[s].poly.count / 2;
				for (int i = 0; i < n; i++) {
					int j = (i + 1) % n;
					float x1 = pts[i * 2 + 0], y1 = pts[i * 2 + 1];
					float x2 = pts[j * 2 + 0], y2 = pts[j * 2 + 1];
					if ((y1 <= syv && y2 > syv) || (y2 <= syv && y1 > syv)) {
						float t = (syv - y1) / (y2 - y1);
						cross[nc].x = x1 + t * (x2 - x1);
						cross[nc].dir = (y2 > y1) ? 1 : -1;
						nc++;
					}
				}
			}

			if (nc < 2) continue;
			qsort(cross, (size_t)nc, sizeof(Crossing), crossingCmp);

			if (evenodd) {
				for (int i = 0; i + 1 < nc; i += 2) {
					addSpan(acc, width, scale, tx, cross[i].x, cross[i + 1].x);
				}
			} else {
				int winding = 0;
				float span_start = 0.0f;
				int have_span = 0;
				for (int i = 0; i < nc; i++) {
					int prev = winding;
					winding += cross[i].dir;
					if (prev == 0 && winding != 0) {
						span_start = cross[i].x;
						have_span = 1;
					} else if (prev != 0 && winding == 0 && have_span) {
						addSpan(acc, width, scale, tx, span_start, cross[i].x);
						have_span = 0;
					}
				}
			}
		}

		unsigned int* row = dst + (size_t)py * (size_t)stride_pixels;
		for (int px = px0; px < px1; px++) {
			float cov = acc[px];
			if (cov <= 0.0f) continue;
			if (cov > 1.0f) cov = 1.0f;

			float src_a = fill_a * cov;
			if (src_a <= 0.001f) continue;
			if (src_a > 1.0f) src_a = 1.0f;

			unsigned int d = row[px];
			float da = ((d >> 24) & 0xFF) / 255.0f;

			if (da <= 0.001f) {
				unsigned int a_byte = (unsigned int)(src_a * 255.0f + 0.5f);
				if (a_byte > 255) a_byte = 255;
				row[px] = (a_byte << 24) | (sr << 16) | (sg << 8) | sb;
			} else {
				float dr = (float)((d >> 16) & 0xFF);
				float dg = (float)((d >> 8) & 0xFF);
				float db = (float)(d & 0xFF);

				float inv_a = 1.0f - src_a;
				float out_a = src_a + da * inv_a;
				if (out_a > 0.0f) {
					float out_r = (sr * src_a + dr * da * inv_a) / out_a;
					float out_g = (sg * src_a + dg * da * inv_a) / out_a;
					float out_b = (sb * src_a + db * da * inv_a) / out_a;

					unsigned int a_byte = (unsigned int)(out_a * 255.0f + 0.5f);
					unsigned int r_byte = (unsigned int)(out_r + 0.5f);
					unsigned int g_byte = (unsigned int)(out_g + 0.5f);
					unsigned int b_byte = (unsigned int)(out_b + 0.5f);
					if (a_byte > 255) a_byte = 255;
					if (r_byte > 255) r_byte = 255;
					if (g_byte > 255) g_byte = 255;
					if (b_byte > 255) b_byte = 255;

					row[px] = (a_byte << 24) | (r_byte << 16) | (g_byte << 8) | b_byte;
				}
			}
		}
	}

	free(cross);
	free(acc);
}

static void strokePathArgb(unsigned int* dst, int width, int height, int stride_pixels,
                           const PointBuf* poly, int closed,
                           float tx, float ty, float scale,
                           unsigned int color, float opacity, float half_width)
{
	const float sub_step = 1.0f / (float)NSVG_SS;
	const int total = NSVG_SS * NSVG_SS;
	const float stroke_a = (((color >> 24) & 0xFF) / 255.0f) * opacity;
	const unsigned int sr = (color >> 16) & 0xFF;
	const unsigned int sg = (color >> 8) & 0xFF;
	const unsigned int sb = color & 0xFF;

	int count = poly->count / 2;
	if (count < 2) return;
	int num_edges = closed ? count : count - 1;

	float pad = (half_width + 1.0f) * scale;
	float half_width_sq = half_width * half_width;

	for (int e = 0; e < num_edges; e++) {
		int next_idx = (e + 1) % count;
		float x1 = poly->pts[e * 2 + 0] * scale + tx;
		float y1 = poly->pts[e * 2 + 1] * scale + ty;
		float x2 = poly->pts[next_idx * 2 + 0] * scale + tx;
		float y2 = poly->pts[next_idx * 2 + 1] * scale + ty;

		int min_px = (int)floorf(fminf(x1, x2) - pad);
		int max_px = (int)ceilf(fmaxf(x1, x2) + pad);
		int min_py = (int)floorf(fminf(y1, y2) - pad);
		int max_py = (int)ceilf(fmaxf(y1, y2) + pad);

		if (min_px < 0) min_px = 0;
		if (min_py < 0) min_py = 0;
		if (max_px > width) max_px = width;
		if (max_py > height) max_py = height;
		if (min_px >= max_px || min_py >= max_py) continue;

		float orig_x1 = poly->pts[e * 2 + 0];
		float orig_y1 = poly->pts[e * 2 + 1];
		float orig_x2 = poly->pts[next_idx * 2 + 0];
		float orig_y2 = poly->pts[next_idx * 2 + 1];

		for (int py = min_py; py < max_py; py++) {
			unsigned int* row = dst + (size_t)py * (size_t)stride_pixels;
			for (int px = min_px; px < max_px; px++) {
				int hits = 0;
				for (int sy = 0; sy < NSVG_SS; sy++) {
					float fy = (float)py + (float)sy * sub_step + sub_step * 0.5f;
					float syv = (fy - ty) / scale;
					for (int sx = 0; sx < NSVG_SS; sx++) {
						float fx = (float)px + (float)sx * sub_step + sub_step * 0.5f;
						float sxv = (fx - tx) / scale;
						float d = distToSegmentSq(sxv, syv, orig_x1, orig_y1, orig_x2, orig_y2);
						if (d <= half_width_sq) hits++;
					}
				}
				if (hits == 0) continue;
				float cov = (float)hits / (float)total;
				float src_a = stroke_a * cov;
				if (src_a <= 0.001f) continue;
				if (src_a > 1.0f) src_a = 1.0f;

				unsigned int d = row[px];
				float da = ((d >> 24) & 0xFF) / 255.0f;

				if (da <= 0.001f) {
					unsigned int a_byte = (unsigned int)(src_a * 255.0f + 0.5f);
					if (a_byte > 255) a_byte = 255;
					row[px] = (a_byte << 24) | (sr << 16) | (sg << 8) | sb;
				} else {
					float dr = (float)((d >> 16) & 0xFF);
					float dg = (float)((d >> 8) & 0xFF);
					float db = (float)(d & 0xFF);

					float inv_a = 1.0f - src_a;
					float out_a = src_a + da * inv_a;
					if (out_a > 0.0f) {
						float out_r = (sr * src_a + dr * da * inv_a) / out_a;
						float out_g = (sg * src_a + dg * da * inv_a) / out_a;
						float out_b = (sb * src_a + db * da * inv_a) / out_a;

						unsigned int a_byte = (unsigned int)(out_a * 255.0f + 0.5f);
						unsigned int r_byte = (unsigned int)(out_r + 0.5f);
						unsigned int g_byte = (unsigned int)(out_g + 0.5f);
						unsigned int b_byte = (unsigned int)(out_b + 0.5f);
						if (a_byte > 255) a_byte = 255;
						if (r_byte > 255) r_byte = 255;
						if (g_byte > 255) g_byte = 255;
						if (b_byte > 255) b_byte = 255;

						row[px] = (a_byte << 24) | (r_byte << 16) | (g_byte << 8) | b_byte;
					}
				}
			}
		}
	}
}

int nsvgRasterizeArgb(NSVGrasterizer* rast,
                      unsigned int* dst, int width, int height, int stride_pixels,
                      NSVGimage* image, float dx, float dy, float scale)
{
	if (!rast || !dst || !image || width <= 0 || height <= 0 || stride_pixels < width || scale <= 0.0f)
		return -1;
	if (image->width <= 0.0f || image->height <= 0.0f) return -1;

	float tol = 0.35f / scale;
	if (tol < 0.02f) tol = 0.02f;
	if (tol > 16.0f) tol = 16.0f;

	NSVGshape* shape = image->shapes;
	while (shape) {
		if (!(shape->flags & NSVG_FLAGS_VISIBLE)) { shape = shape->next; continue; }

		int npaths = 0;
		for (NSVGpath* p = shape->paths; p; p = p->next) npaths++;
		if (npaths == 0) { shape = shape->next; continue; }

		SubPathList subs;
		subs.count = npaths;
		subs.items = (SubPath*)calloc((size_t)npaths, sizeof(SubPath));
		if (!subs.items) { shape = shape->next; continue; }

		int idx = 0;
		for (NSVGpath* p = shape->paths; p; p = p->next, idx++) {
			buildPolyline(p, &subs.items[idx].poly, tol);
			subs.items[idx].closed = p->closed;
		}

		int fill_on = (shape->fill.type == NSVG_PAINT_COLOR) && (((shape->fill.color >> 24) & 0xFF) > 0);
		int stroke_on = (shape->stroke.type == NSVG_PAINT_COLOR) && (((shape->stroke.color >> 24) & 0xFF) > 0) && (shape->strokeWidth > 0.0f);
		float half_width = shape->strokeWidth * 0.5f;

		if (fill_on || stroke_on) {
			float bounds[4];
			boundsOfSubpaths(&subs, half_width + 0.5f, bounds);

			int px0 = (int)floorf(bounds[0] * scale + dx);
			int py0 = (int)floorf(bounds[1] * scale + dy);
			int px1 = (int)ceilf(bounds[2] * scale + dx);
			int py1 = (int)ceilf(bounds[3] * scale + dy);
			if (px0 < 0) px0 = 0;
			if (py0 < 0) py0 = 0;
			if (px1 > width) px1 = width;
			if (py1 > height) py1 = height;

			if (px0 < px1 && py0 < py1) {
				if (fill_on) {
					fillShapeArgb(dst, width, height, stride_pixels, &subs,
					              shape->fillRule == NSVG_FILLRULE_EVENODD,
					              dx, dy, scale, shape->fill.color, shape->opacity, px0, py0, px1, py1);
				}
				if (stroke_on) {
					for (int s = 0; s < subs.count; s++) {
						PointBuf* poly = &subs.items[s].poly;
						if (poly->count < 4) continue;
						strokePathArgb(dst, width, height, stride_pixels, poly, subs.items[s].closed,
						               dx, dy, scale, shape->stroke.color, shape->opacity, half_width);
					}
				}
			}
		}

		for (int s = 0; s < subs.count; s++) bufFree(&subs.items[s].poly);
		free(subs.items);
		shape = shape->next;
	}

	return 0;
}
