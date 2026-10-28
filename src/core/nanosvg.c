/* NanoSVG - simple stupid SVG parser implementation
 *
 * zlib license:
 *
 * Copyright (c) 2013-14 Mikko Mononen memon@inside.org
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>

#include "nanosvg.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

/* Simple string helpers --------------------------------------------------- */

static int nsvg__isspace(char c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',';
}

static int nsvg__isdigit(char c)
{
	return c >= '0' && c <= '9';
}

static float nsvg__atof(const char* s)
{
	return (float)atof(s);
}

static int nsvg__parseXmlName(const char* s, char* dst, int maxLen)
{
	int i = 0;
	while (*s && (nsvg__isdigit(*s) || (*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
	              *s == '-' || *s == '_' || *s == ':' || *s == '.')) {
		if (i < maxLen - 1) dst[i++] = *s;
		s++;
	}
	dst[i] = 0;
	return i;
}

static void nsvg__skipWhite(const char** s)
{
	while (**s && nsvg__isspace(**s)) (*s)++;
}

static const char* nsvg__getNextAttrib(const char* s, char* name, int nameLen, char* value, int valueLen)
{
	int i;
	name[0] = 0;
	value[0] = 0;
	nsvg__skipWhite(&s);
	if (!*s) return NULL;
	i = nsvg__parseXmlName(s, name, nameLen);
	if (i == 0) return NULL;
	s += i;
	nsvg__skipWhite(&s);
	if (*s == '=') {
		s++;
		nsvg__skipWhite(&s);
		if (*s == '"' || *s == '\'') {
			char quote = *s;
			s++;
			i = 0;
			while (*s && *s != quote) {
				if (i < valueLen - 1) value[i++] = *s;
				s++;
			}
			value[i] = 0;
			if (*s) s++;
		} else {
			i = 0;
			while (*s && !nsvg__isspace(*s)) {
				if (i < valueLen - 1) value[i++] = *s;
				s++;
			}
			value[i] = 0;
		}
	}
	return s;
}

/* Very simple, non-validating XML parser. Good enough for the SVG subset we use. */
static int nsvg__parseXML(char* input,
                          void (*startelCb)(void*, const char*, const char**),
                          void (*endelCb)(void*, const char*),
                          void (*contentCb)(void*, const char*),
                          void* ud)
{
	const char* s = input;
	char elname[512];
	char name[512];
	char value[1024];
	/* Attribute names and values must stay alive until the element callback
	 * returns, and each attribute needs its own storage. Earlier versions
	 * stored pointers into the single `name`/`value` scratch buffers, which
	 * left every attribute pointing at the last parsed one and also clobbered
	 * the element name. */
	char attr_names[64][64];
	char attr_values[64][1024];

	while (*s) {
		if (*s == '<') {
			s++;
			if (*s == '/') {
				s++;
				nsvg__skipWhite(&s);
				const char* start = s;
				while (*s && *s != '>') s++;
				int len = (int)(s - start);
				if (len > 511) len = 511;
				memcpy(elname, start, len);
				elname[len] = 0;
				if (endelCb) endelCb(ud, elname);
				if (*s) s++;
			} else if (*s == '?') {
				s++;
				while (*s && !(s[0] == '?' && s[1] == '>')) s++;
				if (s[0]) s += 2;
			} else if (*s == '!') {
				s++;
				if (s[0] == '-' && s[1] == '-') {
					s += 2;
					while (*s && !(s[0] == '-' && s[1] == '-')) s++;
					if (s[0]) s += 2;
				} else {
					while (*s && *s != '>') s++;
					if (*s) s++;
				}
			} else {
				nsvg__skipWhite(&s);
				int elen = nsvg__parseXmlName(s, elname, 511);
				if (elen == 0) { s++; continue; }
				s += elen;
				const char* attrs[130];
				int nattr = 0;
				while (*s && *s != '>' && *s != '/') {
					const char* next = nsvg__getNextAttrib(s, name, 511, value, 1023);
					if (next == NULL || next == s) break;
					if (nattr < 63) {
						int ni = nsvg__parseXmlName(name, attr_names[nattr], 64);
						int vi = 0;
						while (vi < 1023 && value[vi]) { attr_values[nattr][vi] = value[vi]; vi++; }
						attr_values[nattr][vi] = 0;
						attrs[nattr*2] = attr_names[nattr];
						attrs[nattr*2+1] = attr_values[nattr];
						nattr++;
						(void)ni;
					}
					s = next;
				}
				attrs[nattr*2] = NULL;
				attrs[nattr*2+1] = NULL;
				int isSelfClosing = 0;
				if (*s == '/') { isSelfClosing = 1; s++; }
				if (*s == '>') s++;
				if (startelCb) startelCb(ud, elname, (const char**)attrs);
				if (isSelfClosing && endelCb) endelCb(ud, elname);
			}
		} else {
			const char* start = s;
			while (*s && *s != '<') s++;
			int len = (int)(s - start);
			if (contentCb && len > 0) {
				while (len > 0 && nsvg__isspace(start[len-1])) len--;
				if (len > 0) {
					char* tmp = (char*)alloca(len + 1);
					memcpy(tmp, start, len);
					tmp[len] = 0;
					int nonws = 0;
					for (char* p = tmp; *p; p++) if (!nsvg__isspace(*p)) { nonws = 1; break; }
					if (nonws) contentCb(ud, tmp);
				}
			}
		}
	}
	return 1;
}

/* SVG parser context ------------------------------------------------------ */

struct NSVGParser {
	NSVGimage* image;
	NSVGshape* shape;
	NSVGpath* path;
	float px, py;
	float startX, startY;
	int flag;

	NSVGpaint fillPaint;
	NSVGpaint strokePaint;
	float fillOpacity;
	float strokeOpacity;
	float strokeWidth;
	char fillRule;
	char strokeLineCap;
	char strokeLineJoin;
	float opacity;
	unsigned char flags;

	float viewMinx, viewMiny, viewW, viewH;
	int hasViewBox;
	int skip_depth;

	float xforms[32][6];
	int xform_depth;
};
typedef struct NSVGParser NSVGParser;

static void nsvg__xformSetIdentity(float* t)
{
	t[0] = 1.0f; t[1] = 0.0f;
	t[2] = 0.0f; t[3] = 1.0f;
	t[4] = 0.0f; t[5] = 0.0f;
}

static void nsvg__xformMultiply(float* t, const float* s)
{
	float t0 = t[0]*s[0] + t[1]*s[2];
	float t1 = t[0]*s[1] + t[1]*s[3];
	float t2 = t[2]*s[0] + t[3]*s[2];
	float t3 = t[2]*s[1] + t[3]*s[3];
	float t4 = t[4]*s[0] + t[5]*s[2] + s[4];
	float t5 = t[4]*s[1] + t[5]*s[3] + s[5];
	t[0] = t0; t[1] = t1; t[2] = t2; t[3] = t3; t[4] = t4; t[5] = t5;
}

static void nsvg__parseTransform(float* t, const char* str)
{
	if (!str || !*str) return;
	const char* s = str;
	while (*s) {
		while (*s && (*s == ' ' || *s == '\t' || *s == ',')) s++;
		if (!*s) break;

		if (strncmp(s, "matrix", 6) == 0) {
			s += 6;
			while (*s && *s != '(') s++;
			if (*s == '(') s++;
			float m[6] = {1,0,0,1,0,0};
			char* end = NULL;
			m[0] = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			m[1] = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			m[2] = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			m[3] = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			m[4] = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			m[5] = (float)strtod(s, &end); s = end;
			nsvg__xformMultiply(t, m);
			while (*s && *s != ')') s++;
			if (*s == ')') s++;
		} else if (strncmp(s, "translate", 9) == 0) {
			s += 9;
			while (*s && *s != '(') s++;
			if (*s == '(') s++;
			char* end = NULL;
			float tx = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			float ty = 0.0f;
			if (*s && *s != ')') ty = (float)strtod(s, &end);
			float m[6] = { 1.0f, 0.0f, 0.0f, 1.0f, tx, ty };
			nsvg__xformMultiply(t, m);
			while (*s && *s != ')') s++;
			if (*s == ')') s++;
		} else if (strncmp(s, "scale", 5) == 0) {
			s += 5;
			while (*s && *s != '(') s++;
			if (*s == '(') s++;
			char* end = NULL;
			float sx = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			float sy = (*s && *s != ')') ? (float)strtod(s, &end) : sx;
			float m[6] = { sx, 0.0f, 0.0f, sy, 0.0f, 0.0f };
			nsvg__xformMultiply(t, m);
			while (*s && *s != ')') s++;
			if (*s == ')') s++;
		} else if (strncmp(s, "rotate", 6) == 0) {
			s += 6;
			while (*s && *s != '(') s++;
			if (*s == '(') s++;
			char* end = NULL;
			float deg = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
			float rad = deg * 3.14159265358979323846f / 180.0f;
			float cos_a = cosf(rad);
			float sin_a = sinf(rad);
			if (*s && *s != ')') {
				float cx = (float)strtod(s, &end); s = end; while (*s == ',' || *s == ' ') s++;
				float cy = (float)strtod(s, &end);
				float m1[6] = { 1.0f, 0.0f, 0.0f, 1.0f, cx, cy };
				float m2[6] = { cos_a, sin_a, -sin_a, cos_a, 0.0f, 0.0f };
				float m3[6] = { 1.0f, 0.0f, 0.0f, 1.0f, -cx, -cy };
				nsvg__xformMultiply(t, m1);
				nsvg__xformMultiply(t, m2);
				nsvg__xformMultiply(t, m3);
			} else {
				float m[6] = { cos_a, sin_a, -sin_a, cos_a, 0.0f, 0.0f };
				nsvg__xformMultiply(t, m);
			}
			while (*s && *s != ')') s++;
			if (*s == ')') s++;
		} else {
			s++;
		}
	}
}

static NSVGParser* nsvg__createParser(void)
{
	NSVGParser* p = (NSVGParser*)calloc(1, sizeof(NSVGParser));
	if (!p) return NULL;
	p->xform_depth = 0;
	nsvg__xformSetIdentity(p->xforms[0]);
	/* SVG default paint is an opaque black fill and no stroke. */
	p->fillPaint.type = NSVG_PAINT_COLOR;
	p->fillPaint.color = 0xFF000000;
	p->strokePaint.type = NSVG_PAINT_NONE;
	p->fillOpacity = 1.0f;
	p->strokeOpacity = 1.0f;
	p->strokeWidth = 1.0f;
	p->opacity = 1.0f;
	p->flags = NSVG_FLAGS_VISIBLE;
	p->fillRule = NSVG_FILLRULE_NONZERO;
	return p;
}

static void nsvg__deleteParser(NSVGParser* p)
{
	if (!p) return;
	free(p);
}

static void nsvg__resetPath(NSVGParser* p)
{
	p->path = NULL;
	p->px = p->py = 0.0f;
	p->startX = p->startY = 0.0f;
}

static void nsvg__setPaintColor(NSVGpaint* paint, unsigned int color)
{
	paint->type = NSVG_PAINT_COLOR;
	paint->color = color;
}

static NSVGpath* nsvg__addPath(NSVGParser* p)
{
	NSVGpath* path = (NSVGpath*)calloc(1, sizeof(NSVGpath));
	if (!path) return NULL;
	path->pts = NULL;
	path->npts = 0;
	path->closed = 0;
	path->bounds[0] = path->bounds[1] = path->bounds[2] = path->bounds[3] = 0.0f;
	path->next = NULL;
	if (p->shape->paths == NULL) {
		p->shape->paths = path;
	} else {
		NSVGpath* n = p->shape->paths;
		while (n->next) n = n->next;
		n->next = path;
	}
	p->path = path;
	return path;
}

static NSVGshape* nsvg__addShape(NSVGParser* p)
{
	NSVGshape* shape = (NSVGshape*)calloc(1, sizeof(NSVGshape));
	if (!shape) return NULL;
	shape->fill.type = NSVG_PAINT_COLOR;
	shape->fill.color = 0x000000FF;
	shape->stroke.type = NSVG_PAINT_NONE;
	shape->strokeWidth = 1.0f;
	shape->strokeDashCount = 0;
	shape->strokeLineJoin = NSVG_JOIN_MITER;
	shape->strokeLineCap = NSVG_CAP_BUTT;
	shape->fillRule = NSVG_FILLRULE_NONZERO;
	shape->opacity = 1.0f;
	shape->paintOrder = 0;
	shape->flags = NSVG_FLAGS_VISIBLE;
	shape->bounds[0] = shape->bounds[1] = shape->bounds[2] = shape->bounds[3] = 0.0f;
	shape->xform[0] = shape->xform[3] = 1.0f;
	shape->paths = NULL;
	shape->next = NULL;
	if (p->image->shapes == NULL) {
		p->image->shapes = shape;
	} else {
		NSVGshape* n = p->image->shapes;
		while (n->next) n = n->next;
		n->next = shape;
	}
	p->shape = shape;
	p->path = NULL;
	return shape;
}

/* Path data parsing ------------------------------------------------------- */

static int nsvg__pathCommand(char c)
{
	switch (c) {
		case 'M': case 'L': case 'H': case 'V': case 'C': case 'Q': case 'S': case 'T': case 'A': case 'Z':
		case 'm': case 'l': case 'h': case 'v': case 'c': case 'q': case 's': case 't': case 'a': case 'z':
			return 1;
	}
	return 0;
}

static int nsvg__parsePathArgs(const char** s, float* args, int maxArgs)
{
	int n = 0;
	const char* ptr = *s;
	while (n < maxArgs) {
		while (*ptr && nsvg__isspace(*ptr)) ptr++;
		if (!*ptr) break;
		if (nsvg__pathCommand(*ptr)) break;
		char* end = NULL;
		double v = strtod(ptr, &end);
		if (end == ptr) break;
		args[n++] = (float)v;
		ptr = end;
	}
	*s = ptr;
	return n;
}

static void nsvg__moveTo(NSVGParser* p, float x, float y, int relative)
{
	if (relative) { x += p->px; y += p->py; }
	if (p->path == NULL || p->path->npts > 0) {
		nsvg__addPath(p);
	}
	NSVGpath* path = p->path;
	float* pts = (float*)realloc(path->pts, sizeof(float) * (path->npts + 2));
	if (!pts) return;
	path->pts = pts;
	path->pts[path->npts++] = x;
	path->pts[path->npts++] = y;
	p->px = x; p->py = y;
	p->startX = x; p->startY = y;
}

static void nsvg__lineTo(NSVGParser* p, float x, float y, int relative)
{
	if (relative) { x += p->px; y += p->py; }
	if (p->path == NULL || p->path->npts == 0) { nsvg__moveTo(p, x, y, 0); return; }
	NSVGpath* path = p->path;
	int n = path->npts;
	float* pts = (float*)realloc(path->pts, sizeof(float) * (n + 6));
	if (!pts) return;
	path->pts = pts;
	/* Represent the straight segment as an equivalent cubic: control points
	 * at one third and two thirds along the line. */
	pts[n+0] = p->px + (x - p->px) / 3.0f;
	pts[n+1] = p->py + (y - p->py) / 3.0f;
	pts[n+2] = p->px + 2.0f * (x - p->px) / 3.0f;
	pts[n+3] = p->py + 2.0f * (y - p->py) / 3.0f;
	pts[n+4] = x;       pts[n+5] = y;
	path->npts += 6;
	p->px = x; p->py = y;
}

static void nsvg__cubicTo(NSVGParser* p, float c1x, float c1y, float c2x, float c2y, float x, float y, int relative)
{
	if (relative) { c1x += p->px; c1y += p->py; c2x += p->px; c2y += p->py; x += p->px; y += p->py; }
	if (p->path == NULL || p->path->npts == 0) { nsvg__moveTo(p, x, y, 0); return; }
	NSVGpath* path = p->path;
	int n = path->npts;
	/* Exactly one cubic point triple (c1, c2, end); the start point is the
	 * current end point already stored in the path. */
	float* pts = (float*)realloc(path->pts, sizeof(float) * (n + 6));
	if (!pts) return;
	path->pts = pts;
	pts[n+0] = c1x;   pts[n+1] = c1y;
	pts[n+2] = c2x;   pts[n+3] = c2y;
	pts[n+4] = x;     pts[n+5] = y;
	path->npts += 6;
	p->px = x; p->py = y;
}

static void nsvg__closePath(NSVGParser* p)
{
	if (p->path && p->path->npts >= 2) {
		if (p->px != p->startX || p->py != p->startY) {
			nsvg__lineTo(p, p->startX, p->startY, 0);
		}
		p->path->closed = 1;
	}
	p->px = p->startX; p->py = p->startY;
}

static int nsvg__readFloat(const char** s, float* out)
{
	const char* ptr = *s;
	while (*ptr && nsvg__isspace(*ptr)) ptr++;
	/* Also accept the comma/whitespace separators used in compact path data. */
	while (*ptr == ',') ptr++;
	if (!*ptr) return 0;
	if (nsvg__pathCommand(*ptr)) return 0;
	char* end = NULL;
	double v = strtod(ptr, &end);
	if (end == ptr) return 0;
	*out = (float)v;
	*s = end;
	return 1;
}

static float nsvg__angleBetween(float ux, float uy, float vx, float vy)
{
	float dot = ux * vx + uy * vy;
	float len = sqrtf((ux * ux + uy * uy) * (vx * vx + vy * vy));
	if (len <= 0.0f) return 0.0f;
	float c = dot / len;
	if (c < -1.0f) c = -1.0f;
	if (c > 1.0f) c = 1.0f;
	float a = acosf(c);
	if (ux * vy - uy * vx < 0.0f) a = -a;
	return a;
}

/* Approximate an SVG elliptical arc with short line segments. */
static void nsvg__arcTo(NSVGParser* p, float rx, float ry, float rot_deg,
                        int large_arc, int sweep, float ex, float ey, int relative)
{
	if (relative) { ex += p->px; ey += p->py; }
	float x1 = p->px, y1 = p->py;
	if (rx == 0.0f || ry == 0.0f) { nsvg__lineTo(p, ex, ey, 0); return; }
	rx = fabsf(rx); ry = fabsf(ry);
	float phi = rot_deg * (float)M_PI / 180.0f;
	float cs = cosf(phi), sn = sinf(phi);
	float dx = (x1 - ex) * 0.5f;
	float dy = (y1 - ey) * 0.5f;
	float x1p =  cs * dx + sn * dy;
	float y1p = -sn * dx + cs * dy;
	float lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
	if (lambda > 1.0f) {
		float sc = sqrtf(lambda);
		rx *= sc;
		ry *= sc;
	}
	float rx2 = rx * rx, ry2 = ry * ry;
	float x1p2 = x1p * x1p, y1p2 = y1p * y1p;
	float denom = rx2 * y1p2 + ry2 * x1p2;
	float numer = rx2 * ry2 - denom;
	float coef = 0.0f;
	if (denom > 0.0f && numer > 0.0f) {
		coef = sqrtf(numer / denom);
		if (large_arc == sweep) coef = -coef;
	}
	float cxp = coef * (rx * y1p / ry);
	float cyp = coef * (-ry * x1p / rx);
	float cx = cs * cxp - sn * cyp + (x1 + ex) * 0.5f;
	float cy = sn * cxp + cs * cyp + (y1 + ey) * 0.5f;

	float ux = (x1p - cxp) / rx;
	float uy = (y1p - cyp) / ry;
	float vx = (-x1p - cxp) / rx;
	float vy = (-y1p - cyp) / ry;
	float theta1 = nsvg__angleBetween(1.0f, 0.0f, ux, uy);
	float dtheta = nsvg__angleBetween(ux, uy, vx, vy);
	if (!sweep && dtheta > 0.0f) dtheta -= 2.0f * (float)M_PI;
	else if (sweep && dtheta < 0.0f) dtheta += 2.0f * (float)M_PI;

	int steps = (int)ceilf(fabsf(dtheta) / ((float)M_PI / 16.0f));
	if (steps < 2) steps = 2;
	if (steps > 128) steps = 128;
	float step = dtheta / (float)steps;
	for (int i = 1; i <= steps; i++) {
		float t = theta1 + step * (float)i;
		float ct = cosf(t), st = sinf(t);
		float px = cx + cs * rx * ct - sn * ry * st;
		float py = cy + sn * rx * ct + cs * ry * st;
		nsvg__lineTo(p, px, py, 0);
	}
}

static void nsvg__parsePathData(NSVGParser* p, const char* d)
{
	const char* ptr = d;
	char cmd = 0;
	float prev_c2x = 0.0f, prev_c2y = 0.0f;
	float prev_qx = 0.0f, prev_qy = 0.0f;
	int prev_was_cubic = 0;
	int prev_was_quad = 0;

	while (*ptr) {
		while (*ptr && nsvg__isspace(*ptr)) ptr++;
		if (!*ptr) break;

		if (nsvg__pathCommand(*ptr)) {
			cmd = *ptr++;
			if (cmd == 'Z' || cmd == 'z') {
				nsvg__closePath(p);
				cmd = 0;
				prev_was_cubic = prev_was_quad = 0;
				continue;
			}
			continue;
		}
		if (!cmd) { ptr++; continue; }

		int rel = (cmd >= 'a' && cmd <= 'z');
		char ucmd = (cmd >= 'A' && cmd <= 'Z') ? cmd : (char)(cmd - 32);
		float a[7];
		int arity = 0;
		switch (ucmd) {
			case 'M': case 'L': case 'T': arity = 2; break;
			case 'H': case 'V': arity = 1; break;
			case 'C': arity = 6; break;
			case 'S': case 'Q': arity = 4; break;
			case 'A': arity = 7; break;
			default: cmd = 0; continue;
		}
		int ok = 1;
		for (int i = 0; i < arity; i++) {
			if (!nsvg__readFloat(&ptr, &a[i])) { ok = 0; break; }
		}
		if (!ok) break;

		switch (ucmd) {
			case 'M': {
				if (rel) { a[0] += p->px; a[1] += p->py; }
				nsvg__moveTo(p, a[0], a[1], 0);
				/* Subsequent coordinate pairs are implicit line-to commands. */
				cmd = rel ? 'l' : 'L';
				prev_was_cubic = prev_was_quad = 0;
				break;
			}
			case 'L': {
				if (rel) { a[0] += p->px; a[1] += p->py; }
				nsvg__lineTo(p, a[0], a[1], 0);
				prev_was_cubic = prev_was_quad = 0;
				break;
			}
			case 'H': {
				float x = rel ? p->px + a[0] : a[0];
				nsvg__lineTo(p, x, p->py, 0);
				prev_was_cubic = prev_was_quad = 0;
				break;
			}
			case 'V': {
				float y = rel ? p->py + a[0] : a[0];
				nsvg__lineTo(p, p->px, y, 0);
				prev_was_cubic = prev_was_quad = 0;
				break;
			}
			case 'C': {
				float c1x = a[0], c1y = a[1], c2x = a[2], c2y = a[3], x = a[4], y = a[5];
				if (rel) { c1x += p->px; c1y += p->py; c2x += p->px; c2y += p->py; x += p->px; y += p->py; }
				nsvg__cubicTo(p, c1x, c1y, c2x, c2y, x, y, 0);
				prev_c2x = c2x; prev_c2y = c2y;
				prev_was_cubic = 1; prev_was_quad = 0;
				break;
			}
			case 'S': {
				float c1x = prev_was_cubic ? 2.0f * p->px - prev_c2x : p->px;
				float c1y = prev_was_cubic ? 2.0f * p->py - prev_c2y : p->py;
				float c2x = a[0], c2y = a[1], x = a[2], y = a[3];
				if (rel) { c2x += p->px; c2y += p->py; x += p->px; y += p->py; }
				nsvg__cubicTo(p, c1x, c1y, c2x, c2y, x, y, 0);
				prev_c2x = c2x; prev_c2y = c2y;
				prev_was_cubic = 1; prev_was_quad = 0;
				break;
			}
			case 'Q': {
				float qx = a[0], qy = a[1], x = a[2], y = a[3];
				if (rel) { qx += p->px; qy += p->py; x += p->px; y += p->py; }
				float c1x = p->px + (qx - p->px) * 2.0f / 3.0f;
				float c1y = p->py + (qy - p->py) * 2.0f / 3.0f;
				float c2x = x + (qx - x) * 2.0f / 3.0f;
				float c2y = y + (qy - y) * 2.0f / 3.0f;
				nsvg__cubicTo(p, c1x, c1y, c2x, c2y, x, y, 0);
				prev_qx = qx; prev_qy = qy;
				prev_was_quad = 1; prev_was_cubic = 0;
				break;
			}
			case 'T': {
				float qx = prev_was_quad ? 2.0f * p->px - prev_qx : p->px;
				float qy = prev_was_quad ? 2.0f * p->py - prev_qy : p->py;
				float x = a[0], y = a[1];
				if (rel) { x += p->px; y += p->py; }
				float c1x = p->px + (qx - p->px) * 2.0f / 3.0f;
				float c1y = p->py + (qy - p->py) * 2.0f / 3.0f;
				float c2x = x + (qx - x) * 2.0f / 3.0f;
				float c2y = y + (qy - y) * 2.0f / 3.0f;
				nsvg__cubicTo(p, c1x, c1y, c2x, c2y, x, y, 0);
				prev_qx = qx; prev_qy = qy;
				prev_was_quad = 1; prev_was_cubic = 0;
				break;
			}
			case 'A': {
				nsvg__arcTo(p, a[0], a[1], a[2], (int)a[3], (int)a[4], a[5], a[6], rel);
				prev_was_cubic = prev_was_quad = 0;
				break;
			}
		}
	}
}

/* Color parsing ----------------------------------------------------------- */

typedef struct {
	const char* name;
	unsigned int color;
} NSVGnamedColor;

static const NSVGnamedColor nsvg__namedColors[] = {
	{ "black", 0xFF000000 },
	{ "white", 0xFFFFFFFF },
	{ "red", 0xFFFF0000 },
	{ "green", 0xFF008000 },
	{ "blue", 0xFF0000FF },
	{ "yellow", 0xFFFFFF00 },
	{ "cyan", 0xFF00FFFF },
	{ "aqua", 0xFF00FFFF },
	{ "magenta", 0xFFFF00FF },
	{ "fuchsia", 0xFFFF00FF },
	{ "gray", 0xFF808080 },
	{ "grey", 0xFF808080 },
	{ "darkgray", 0xFFA9A9A9 },
	{ "darkgrey", 0xFFA9A9A9 },
	{ "lightgray", 0xFFD3D3D3 },
	{ "lightgrey", 0xFFD3D3D3 },
	{ "silver", 0xFFC0C0C0 },
	{ "maroon", 0xFF800000 },
	{ "olive", 0xFF808000 },
	{ "lime", 0xFF00FF00 },
	{ "navy", 0xFF000080 },
	{ "teal", 0xFF008080 },
	{ "orange", 0xFFFFA500 },
	{ "purple", 0xFF800080 },
	{ "violet", 0xFFEE82EE },
	{ "pink", 0xFFFFC0CB },
	{ "brown", 0xFFA52A2A },
	{ "gold", 0xFFFFD700 },
	{ "none", 0x00000000 },
	{ "transparent", 0x00000000 },
	{ NULL, 0 }
};

static unsigned int nsvg__parseHex(const char* str, int len)
{
	unsigned int r = 0, g = 0, b = 0, a = 255;
	if (len == 6) {
		sscanf(str, "%2x%2x%2x", &r, &g, &b);
	} else if (len == 8) {
		sscanf(str, "%2x%2x%2x%2x", &r, &g, &b, &a);
	} else if (len == 3) {
		char one[3] = { str[0], str[0], 0 };
		char two[3] = { str[1], str[1], 0 };
		char thr[3] = { str[2], str[2], 0 };
		r = (unsigned int)strtoul(one, NULL, 16);
		g = (unsigned int)strtoul(two, NULL, 16);
		b = (unsigned int)strtoul(thr, NULL, 16);
	} else if (len == 4) {
		char one[3] = { str[0], str[0], 0 };
		char two[3] = { str[1], str[1], 0 };
		char thr[3] = { str[2], str[2], 0 };
		char fou[3] = { str[3], str[3], 0 };
		r = (unsigned int)strtoul(one, NULL, 16);
		g = (unsigned int)strtoul(two, NULL, 16);
		b = (unsigned int)strtoul(thr, NULL, 16);
		a = (unsigned int)strtoul(fou, NULL, 16);
	}
	return (a << 24) | (r << 16) | (g << 8) | b;
}

static unsigned int nsvg__parseColor(const char* str)
{
	if (!str) return 0xFF000000;
	while (*str && (*str == ' ' || *str == '\t')) str++;
	if (!*str) return 0xFF000000;

	if (str[0] == '#') {
		str++;
		int len = (int)strlen(str);
		while (len > 0 && (str[len-1] == ' ' || str[len-1] == '\t')) len--;
		if (len == 6 || len == 3 || len == 8 || len == 4) return nsvg__parseHex(str, len);
		return 0xFF000000;
	}
	if (strncmp(str, "rgb(", 4) == 0 || strncmp(str, "rgba(", 5) == 0) {
		const char* p = strchr(str, '(');
		if (p) p++;
		else p = str;
		float rf = 0.0f, gf = 0.0f, bf = 0.0f, af = 1.0f;
		if (strchr(p, '%')) {
			sscanf(p, "%f%% , %f%% , %f%%", &rf, &gf, &bf);
			rf *= 2.55f;
			gf *= 2.55f;
			bf *= 2.55f;
		} else {
			sscanf(p, "%f , %f , %f", &rf, &gf, &bf);
		}
		const char* c1 = strchr(p, ',');
		if (c1) {
			const char* c2 = strchr(c1 + 1, ',');
			if (c2) {
				const char* c3 = strchr(c2 + 1, ',');
				if (c3) {
					sscanf(c3 + 1, "%f", &af);
					if (strchr(c3 + 1, '%')) af /= 100.0f;
				}
			}
		}
		int r = (int)(rf + 0.5f); if (r < 0) r = 0; if (r > 255) r = 255;
		int g = (int)(gf + 0.5f); if (g < 0) g = 0; if (g > 255) g = 255;
		int b = (int)(bf + 0.5f); if (b < 0) b = 0; if (b > 255) b = 255;
		int a = (int)(af * 255.0f + 0.5f); if (a < 0) a = 0; if (a > 255) a = 255;
		return ((unsigned int)a << 24) | ((unsigned int)r << 16) | ((unsigned int)g << 8) | (unsigned int)b;
	}

	for (int i = 0; nsvg__namedColors[i].name != NULL; i++) {
		if (strcmp(str, nsvg__namedColors[i].name) == 0) {
			return nsvg__namedColors[i].color;
		}
	}

	return 0xFF000000;
}

static void nsvg__parseAttribs(NSVGParser* p, const char** attr);

static void nsvg__parseStyle(NSVGParser* p, const char* style)
{
	const char* s = style;
	char name[64];
	char val[256];
	while (*s) {
		while (*s && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == ';')) s++;
		if (!*s) break;
		int ni = 0;
		while (*s && *s != ':' && *s != ';' && ni < 63) {
			if (*s != ' ' && *s != '\t') name[ni++] = *s;
			s++;
		}
		name[ni] = 0;
		if (*s == ':') s++;
		while (*s && (*s == ' ' || *s == '\t')) s++;
		int vi = 0;
		while (*s && *s != ';' && vi < 255) {
			val[vi++] = *s++;
		}
		while (vi > 0 && (val[vi-1] == ' ' || val[vi-1] == '\t')) vi--;
		val[vi] = 0;
		if (*s == ';') s++;

		const char* pair[3] = { name, val, NULL };
		nsvg__parseAttribs(p, pair);
	}
}

static void nsvg__parseAttribs(NSVGParser* p, const char** attr)
{
	int i = 0;
	while (attr && attr[i]) {
		const char* name = attr[i];
		const char* value = attr[i+1];
		i += 2;
		if (!name || !value) continue;
		if (strcmp(name, "style") == 0) {
			nsvg__parseStyle(p, value);
		} else if (strcmp(name, "fill") == 0) {
			if (strcmp(value, "none") == 0 || strcmp(value, "transparent") == 0) nsvg__setPaintColor(&p->fillPaint, 0x00000000);
			else nsvg__setPaintColor(&p->fillPaint, nsvg__parseColor(value));
		} else if (strcmp(name, "stroke") == 0) {
			if (strcmp(value, "none") == 0 || strcmp(value, "transparent") == 0) nsvg__setPaintColor(&p->strokePaint, 0x00000000);
			else nsvg__setPaintColor(&p->strokePaint, nsvg__parseColor(value));
		} else if (strcmp(name, "fill-opacity") == 0) {
			p->fillOpacity = nsvg__atof(value);
		} else if (strcmp(name, "stroke-opacity") == 0) {
			p->strokeOpacity = nsvg__atof(value);
		} else if (strcmp(name, "opacity") == 0) {
			p->opacity = nsvg__atof(value);
		} else if (strcmp(name, "stroke-width") == 0) {
			p->strokeWidth = nsvg__atof(value);
		} else if (strcmp(name, "fill-rule") == 0) {
			if (strcmp(value, "evenodd") == 0) p->fillRule = NSVG_FILLRULE_EVENODD;
			else p->fillRule = NSVG_FILLRULE_NONZERO;
		} else if (strcmp(name, "stroke-linecap") == 0) {
			if (strcmp(value, "round") == 0) p->strokeLineCap = NSVG_CAP_ROUND;
			else if (strcmp(value, "square") == 0) p->strokeLineCap = NSVG_CAP_SQUARE;
			else p->strokeLineCap = NSVG_CAP_BUTT;
		} else if (strcmp(name, "stroke-linejoin") == 0) {
			if (strcmp(value, "round") == 0) p->strokeLineJoin = NSVG_JOIN_ROUND;
			else if (strcmp(value, "bevel") == 0) p->strokeLineJoin = NSVG_JOIN_BEVEL;
			else p->strokeLineJoin = NSVG_JOIN_MITER;
		} else if (strcmp(name, "display") == 0) {
			if (strcmp(value, "none") == 0) p->flags &= (unsigned char)~NSVG_FLAGS_VISIBLE;
		}
	}
}

static const char* nsvg__attrValue(const char** attr, const char* key)
{
	for (int i = 0; attr && attr[i]; i += 2) {
		if (attr[i + 1] && strcmp(attr[i], key) == 0) return attr[i + 1];
	}
	return NULL;
}

/* Emit a shape from a generated path string. Paint/style attributes are
 * scoped to this shape, matching the <path> handling below. */
static void nsvg__emitPath(NSVGParser* p, const char** attr, const char* d)
{
	if (!d || !*d) return;

	NSVGpaint saved_fill = p->fillPaint;
	NSVGpaint saved_stroke = p->strokePaint;
	float saved_fill_opacity = p->fillOpacity;
	float saved_stroke_opacity = p->strokeOpacity;
	float saved_opacity = p->opacity;
	float saved_stroke_width = p->strokeWidth;
	char saved_fill_rule = p->fillRule;
	char saved_cap = p->strokeLineCap;
	char saved_join = p->strokeLineJoin;
	unsigned char saved_flags = p->flags;

	nsvg__parseAttribs(p, attr);

	NSVGshape* shape = nsvg__addShape(p);
	if (!shape) return;
	shape->fill = p->fillPaint;
	shape->stroke = p->strokePaint;
	shape->strokeWidth = p->strokeWidth;
	shape->fillRule = p->fillRule;
	shape->strokeLineCap = p->strokeLineCap;
	shape->strokeLineJoin = p->strokeLineJoin;
	shape->opacity = p->opacity * (p->fillPaint.type == NSVG_PAINT_COLOR ? p->fillOpacity : p->strokeOpacity);
	shape->flags = p->flags;

	float final_t[6];
	memcpy(final_t, p->xforms[p->xform_depth], sizeof(float) * 6);
	const char* tf = nsvg__attrValue(attr, "transform");
	if (tf) {
		nsvg__parseTransform(final_t, tf);
	}
	memcpy(shape->xform, final_t, sizeof(float) * 6);

	nsvg__parsePathData(p, d);

	int is_identity = (shape->xform[0] == 1.0f && shape->xform[1] == 0.0f &&
	                   shape->xform[2] == 0.0f && shape->xform[3] == 1.0f &&
	                   shape->xform[4] == 0.0f && shape->xform[5] == 0.0f);
	if (!is_identity) {
		for (NSVGpath* path = shape->paths; path; path = path->next) {
			for (int j = 0; j + 1 < path->npts; j += 2) {
				float px = path->pts[j + 0];
				float py = path->pts[j + 1];
				path->pts[j + 0] = px * shape->xform[0] + py * shape->xform[2] + shape->xform[4];
				path->pts[j + 1] = px * shape->xform[1] + py * shape->xform[3] + shape->xform[5];
			}
		}
	}

	p->fillPaint = saved_fill;
	p->strokePaint = saved_stroke;
	p->fillOpacity = saved_fill_opacity;
	p->strokeOpacity = saved_stroke_opacity;
	p->opacity = saved_opacity;
	p->strokeWidth = saved_stroke_width;
	p->fillRule = saved_fill_rule;
	p->strokeLineCap = saved_cap;
	p->strokeLineJoin = saved_join;
	p->flags = saved_flags;
}

static float nsvg__attrFloat(const char** attr, const char* key, float fallback)
{
	const char* v = nsvg__attrValue(attr, key);
	return v ? nsvg__atof(v) : fallback;
}

static void nsvg__rectPath(const char** attr, char* out, int outLen)
{
	float x = nsvg__attrFloat(attr, "x", 0.0f);
	float y = nsvg__attrFloat(attr, "y", 0.0f);
	float w = nsvg__attrFloat(attr, "width", 0.0f);
	float h = nsvg__attrFloat(attr, "height", 0.0f);
	if (w <= 0.0f || h <= 0.0f) { out[0] = 0; return; }

	float rx = nsvg__attrFloat(attr, "rx", -1.0f);
	float ry = nsvg__attrFloat(attr, "ry", -1.0f);
	if (rx < 0.0f) rx = ry;
	if (ry < 0.0f) ry = rx;
	if (rx < 0.0f) rx = 0.0f;
	if (ry < 0.0f) ry = 0.0f;
	if (rx > w * 0.5f) rx = w * 0.5f;
	if (ry > h * 0.5f) ry = h * 0.5f;

	if (rx <= 0.0f || ry <= 0.0f) {
		snprintf(out, (size_t)outLen, "M %.6g %.6g H %.6g V %.6g H %.6g Z",
		         x, y, x + w, y + h, x);
	} else {
		snprintf(out, (size_t)outLen,
		         "M %.6g %.6g H %.6g A %.6g %.6g 0 0 1 %.6g %.6g V %.6g "
		         "A %.6g %.6g 0 0 1 %.6g %.6g H %.6g A %.6g %.6g 0 0 1 %.6g %.6g "
		         "V %.6g A %.6g %.6g 0 0 1 %.6g %.6g Z",
		         x + rx, y, x + w - rx,
		         rx, ry, x + w, y + ry,
		         y + h - ry,
		         rx, ry, x + w - rx, y + h,
		         x + rx,
		         rx, ry, x, y + h - ry,
		         y + ry,
		         rx, ry, x + rx, y);
	}
}

static void nsvg__ellipsePath(const char** attr, char* out, int outLen)
{
	float cx = nsvg__attrFloat(attr, "cx", 0.0f);
	float cy = nsvg__attrFloat(attr, "cy", 0.0f);
	float rx = nsvg__attrFloat(attr, "r", -1.0f);
	float ry = nsvg__attrFloat(attr, "ry", rx);
	if (rx < 0.0f) rx = nsvg__attrFloat(attr, "rx", 0.0f);
	if (ry < 0.0f) ry = rx;
	if (rx <= 0.0f || ry <= 0.0f) { out[0] = 0; return; }
	snprintf(out, (size_t)outLen,
	         "M %.6g %.6g A %.6g %.6g 0 1 0 %.6g %.6g A %.6g %.6g 0 1 0 %.6g %.6g Z",
	         cx - rx, cy, rx, ry, cx + rx, cy, rx, ry, cx - rx, cy);
}

static void nsvg__pointsPath(const char** attr, int close, char* out, int outLen)
{
	const char* pts = nsvg__attrValue(attr, "points");
	if (!pts) { out[0] = 0; return; }
	int o = 0;
	int first = 1;
	const char* s = pts;
	while (*s) {
		while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == ',') s++;
		if (!*s) break;
		char* end = NULL;
		double x = strtod(s, &end);
		if (end == s) break;
		s = end;
		while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == ',') s++;
		if (!*s) break;
		double y = strtod(s, &end);
		if (end == s) break;
		s = end;
		if (o + 64 < outLen) {
			o += snprintf(out + o, (size_t)(outLen - o), "%c %.6g %.6g", first ? 'M' : 'L', x, y);
			first = 0;
		}
	}
	if (!first && close && o + 4 < outLen) {
		out[o++] = ' ';
		out[o++] = 'Z';
		out[o] = 0;
	}
	if (first) out[0] = 0;
}

static void nsvg__linePath(const char** attr, char* out, int outLen)
{
	snprintf(out, (size_t)outLen, "M %.6g %.6g L %.6g %.6g",
	         nsvg__attrFloat(attr, "x1", 0.0f), nsvg__attrFloat(attr, "y1", 0.0f),
	         nsvg__attrFloat(attr, "x2", 0.0f), nsvg__attrFloat(attr, "y2", 0.0f));
}

static int nsvg__isSkippedContainer(const char* el)
{
	return strcmp(el, "defs") == 0 || strcmp(el, "title") == 0 ||
	       strcmp(el, "desc") == 0 || strcmp(el, "style") == 0 ||
	       strcmp(el, "clipPath") == 0 || strcmp(el, "mask") == 0 ||
	       strcmp(el, "symbol") == 0 || strcmp(el, "pattern") == 0;
}

static void nsvg__startElement(void* ud, const char* el, const char** attr)
{
	NSVGParser* p = (NSVGParser*)ud;
	if (p->skip_depth > 0) {
		p->skip_depth++;
		return;
	}
	if (nsvg__isSkippedContainer(el)) {
		p->skip_depth = 1;
		return;
	}
	if (strcmp(el, "svg") == 0) {
		nsvg__resetPath(p);
		nsvg__parseAttribs(p, attr);

		/* Read the viewBox and viewport dimensions from the real attributes.
		 * Do not scan the raw XML text for "width": that also matches
		 * "stroke-width" and produces wildly incorrect icon sizes. */
		const char* vb = nsvg__attrValue(attr, "viewBox");
		if (vb) {
			float vals[4] = {0, 0, 0, 0};
			int nv = 0;
			const char* vs = vb;
			while (*vs && nv < 4) {
				if (nsvg__isdigit(*vs) || *vs == '.' || *vs == '-' || *vs == '+') {
					char* end = NULL;
					double v = strtod(vs, &end);
					if (end == vs) break;
					vals[nv++] = (float)v;
					vs = end;
				} else {
					vs++;
				}
			}
			if (nv >= 4 && vals[2] > 0.0f && vals[3] > 0.0f) {
				p->viewMinx = vals[0];
				p->viewMiny = vals[1];
				p->viewW = vals[2];
				p->viewH = vals[3];
				p->hasViewBox = 1;
			}
		}
		const char* w = nsvg__attrValue(attr, "width");
		const char* h = nsvg__attrValue(attr, "height");
		if (w) p->image->width = nsvg__atof(w);
		if (h) p->image->height = nsvg__atof(h);
	} else if (strcmp(el, "g") == 0) {
		if (p->xform_depth < 31) {
			p->xform_depth++;
			memcpy(p->xforms[p->xform_depth], p->xforms[p->xform_depth - 1], sizeof(float) * 6);
		}
		const char* tf = nsvg__attrValue(attr, "transform");
		if (tf) {
			nsvg__parseTransform(p->xforms[p->xform_depth], tf);
		}
		nsvg__parseAttribs(p, attr);
	} else if (strcmp(el, "path") == 0) {
		nsvg__emitPath(p, attr, nsvg__attrValue(attr, "d"));
	} else if (strcmp(el, "rect") == 0) {
		char d[1024];
		nsvg__rectPath(attr, d, (int)sizeof(d));
		nsvg__emitPath(p, attr, d);
	} else if (strcmp(el, "circle") == 0 || strcmp(el, "ellipse") == 0) {
		char d[1024];
		nsvg__ellipsePath(attr, d, (int)sizeof(d));
		nsvg__emitPath(p, attr, d);
	} else if (strcmp(el, "line") == 0) {
		char d[512];
		nsvg__linePath(attr, d, (int)sizeof(d));
		nsvg__emitPath(p, attr, d);
	} else if (strcmp(el, "polygon") == 0 || strcmp(el, "polyline") == 0) {
		const char* pts = nsvg__attrValue(attr, "points");
		int len = pts ? (int)strlen(pts) : 0;
		char* d = (char*)malloc((size_t)len * 4 + 128);
		if (d) {
			nsvg__pointsPath(attr, strcmp(el, "polygon") == 0, d, len * 4 + 128);
			nsvg__emitPath(p, attr, d);
			free(d);
		}
	}
}

static void nsvg__endElement(void* ud, const char* el)
{
	NSVGParser* p = (NSVGParser*)ud;
	if (p && p->skip_depth > 0) {
		p->skip_depth--;
		return;
	}
	if (p && strcmp(el, "g") == 0) {
		if (p->xform_depth > 0) p->xform_depth--;
	}
}

NSVGimage* nsvgParse(char* input, const char* units, float dpi)
{
	(void)units; (void)dpi;
	if (!input) return NULL;
	NSVGParser* p = nsvg__createParser();
	if (!p) return NULL;

	NSVGimage* image = (NSVGimage*)calloc(1, sizeof(NSVGimage));
	if (!image) { nsvg__deleteParser(p); return NULL; }
	image->width = 0; image->height = 0; image->shapes = NULL;
	p->image = image;

	if (!nsvg__parseXML(input, nsvg__startElement, nsvg__endElement, NULL, p)) {
		nsvgDelete(image);
		nsvg__deleteParser(p);
		return NULL;
	}

	/* Normalize into viewBox coordinate space. SVG viewport width/height
	 * may differ from the viewBox (e.g. width="64" viewBox="0 0 24 24");
	 * paths are expressed in viewBox units, so render against those. */
	if (p->hasViewBox && p->viewW > 0.0f && p->viewH > 0.0f) {
		for (NSVGshape* shape = image->shapes; shape; shape = shape->next) {
			for (NSVGpath* path = shape->paths; path; path = path->next) {
				for (int i = 0; i + 1 < path->npts; i += 2) {
					path->pts[i + 0] -= p->viewMinx;
					path->pts[i + 1] -= p->viewMiny;
				}
			}
		}
		image->width = p->viewW;
		image->height = p->viewH;
	}
	if (image->width <= 0) image->width = 32.0f;
	if (image->height <= 0) image->height = 32.0f;

	nsvg__deleteParser(p);
	return image;
}

NSVGimage* nsvgParseFromFile(const char* filename, const char* units, float dpi)
{
	if (!filename) return NULL;
	FILE* fp = fopen(filename, "rb");
	if (!fp) return NULL;
	fseek(fp, 0, SEEK_END);
	long sz = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	if (sz <= 0) { fclose(fp); return NULL; }
	char* buf = (char*)malloc((size_t)sz + 1);
	if (!buf) { fclose(fp); return NULL; }
	long rd = fread(buf, 1, (size_t)sz, fp);
	buf[rd] = 0;
	fclose(fp);
	NSVGimage* img = nsvgParse(buf, units, dpi);
	free(buf);
	return img;
}

void nsvgDelete(NSVGimage* image)
{
	if (!image) return;
	NSVGshape* shape = image->shapes;
	while (shape) {
		NSVGshape* next = shape->next;
		NSVGpath* path = shape->paths;
		while (path) {
			NSVGpath* pnext = path->next;
			free(path->pts);
			free(path);
			path = pnext;
		}
		free(shape);
		shape = next;
	}
	free(image);
}
