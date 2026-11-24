#include <metal_stdlib>
using namespace metal;

// Custom frame generation: makes the picture halfway between two decoded frames.
//
// 1. Each frame's luma is shrunk to 1/4 and 1/8 size, and the 1/4 copy's
//    gradients are worked out.
// 2. Motion is searched on the 1/8 copy in 32 px blocks. Overlapping 32 px
//    patches on the 1/4 copy pick the best nearby vector, then slide to the
//    exact (sub-pixel) fit with a few Lucas-Kanade steps, and a median filter
//    removes stray ones.
// 3. The patches are merged into a motion map with one vector per 1/4 pixel:
//    each pixel takes mostly the vectors of the patches it fits best, so the
//    motion follows object edges instead of block edges.
// 4. Every output pixel looks back along the motion into the previous frame and
//    forward into the current one, and blends the two. Of the motion there,
//    the motion a few pixels away (for edges) and "no motion" (keeps HUDs
//    still), the ones whose two samples agree best get the most weight.
//
// Motion is stored as the half motion `d`, in full-size luma pixels: a point
// at `p` in the generated frame was at `p - d` in the previous frame and is at
// `p + d` in the current one.

// Must match FGParams in FrameGenerator.swift
struct FGParams {
	float2 lumaSize;
	float2 chromaSize;
	float2 quarterSize;
	float2 eighthSize;
	int2 coarseCount;  // 32 px blocks
	int2 fineCount;    // 16 px blocks
};

constexpr sampler fgLinear(filter::linear, address::clamp_to_edge, coord::normalized);


constant int FG_BLOCK = 4;          // block size in the shrunk images
constant int FG_COARSE_RANGE = 6;   // 1/8 px each way per frame: up to 96 full px of motion per frame

constant float FG_NEWER_WEIGHT = 0.75;  // share of the newer frame in the blend

// MARK: - Shrinking

// Full luma -> 1/4 size, a 4x4 box made of four bilinear taps
kernel void fg_reduce4(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant FGParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
	float2 base = float2(gid) * 4.0;
	float2 inv = 1.0 / p.lumaSize;
	float s = src.sample(fgLinear, (base + float2(1, 1)) * inv).r
	        + src.sample(fgLinear, (base + float2(3, 1)) * inv).r
	        + src.sample(fgLinear, (base + float2(1, 3)) * inv).r
	        + src.sample(fgLinear, (base + float2(3, 3)) * inv).r;
	dst.write(float4(s * 0.25), gid);
}

// 1/4 size luma -> (luma, d/dx, d/dy), for the Lucas-Kanade steps
kernel void fg_gradient(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
	int w = src.get_width(), h = src.get_height();
	if (int(gid.x) >= w || int(gid.y) >= h) return;
	int2 c = int2(gid);
	float l = src.read(uint2(max(c.x - 1, 0), c.y)).r, r = src.read(uint2(min(c.x + 1, w - 1), c.y)).r;
	float u = src.read(uint2(c.x, max(c.y - 1, 0))).r, d = src.read(uint2(c.x, min(c.y + 1, h - 1))).r;
	dst.write(float4(src.read(gid).r, (r - l) * 0.5, (d - u) * 0.5, 0), gid);
}

// 1/4 -> 1/8 size
kernel void fg_reduce2(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant FGParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
	float2 uv = (float2(gid) * 2.0 + 1.0) / p.quarterSize;
	dst.write(float4(src.sample(fgLinear, uv).r), gid);
}

// MARK: - Motion search

static float fg_read(texture2d<float, access::read> t, int2 c) {
	c = clamp(c, int2(0), int2(t.get_width() - 1, t.get_height() - 1));
	return t.read(uint2(c)).r;
}

// Exhaustive search on the 1/8 images, one 4x4 block (+1 px border) per
// threadgroup: the block's neighbourhood in both images is copied to
// threadgroup memory, each thread tries some of the 25 x 25 candidates, and
// the best (first in row order on a tie) wins. Candidates are whole 1/8 px
// of total motion D, split as evenly as possible between the two frames
// (previous at -floor(D/2), current at +ceil(D/2)). Moving each frame by the
// same whole number instead only covers even motion, 16 full px apart: a
// 23 px pan was 7 px off either way, enough for many blocks to lock on to
// something else.
//
// The ranges are separate so sideways can be tuned on its own. Widening it
// to 144 px was tried for poles sweeping past the screen edges at 100+ px a
// frame: it added false matches elsewhere and didn't fix them (a thin pole is
// outvoted by its background in the later smoothing stages anyway).
constant int FG_COARSE_RANGE_X = 6;  // up to 96 full px of sideways motion per frame
constant int FG_COARSE_SPAN_X = 4 * FG_COARSE_RANGE_X + 1;
constant int FG_COARSE_SPAN = 4 * FG_COARSE_RANGE + 1;
constant int FG_COARSE_TILE_X = FG_BLOCK + 2 + 2 * FG_COARSE_RANGE_X;  // -1 - range ... BLOCK + range
constant int FG_COARSE_TILE = FG_BLOCK + 2 + 2 * FG_COARSE_RANGE;
constant uint FG_COARSE_THREADS = 128;

kernel void fg_coarse(texture2d<float, access::read> prev [[texture(0)]],
                      texture2d<float, access::read> curr [[texture(1)]],
                      texture2d<float, access::write> field [[texture(2)]],
                      constant FGParams &p [[buffer(0)]],
                      uint2 block [[threadgroup_position_in_grid]],
                      uint tid [[thread_index_in_threadgroup]]) {
	threadgroup float tp[FG_COARSE_TILE_X * FG_COARSE_TILE];
	threadgroup float tc[FG_COARSE_TILE_X * FG_COARSE_TILE];
	threadgroup float bestCost[FG_COARSE_THREADS];
	threadgroup int bestIndex[FG_COARSE_THREADS];
	if (int(block.x) >= p.coarseCount.x || int(block.y) >= p.coarseCount.y) return;
	int2 base = int2(block) * FG_BLOCK;
	int2 origin = base - int2(1 + FG_COARSE_RANGE_X, 1 + FG_COARSE_RANGE);
	for (uint i = tid; i < uint(FG_COARSE_TILE_X * FG_COARSE_TILE); i += FG_COARSE_THREADS) {
		int2 q = origin + int2(i % FG_COARSE_TILE_X, i / FG_COARSE_TILE_X);
		tp[i] = fg_read(prev, q);
		tc[i] = fg_read(curr, q);
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);

	float best = INFINITY;
	int bestI = 0;
	for (int c = int(tid); c < FG_COARSE_SPAN_X * FG_COARSE_SPAN; c += int(FG_COARSE_THREADS)) {
		int2 total = int2(c % FG_COARSE_SPAN_X, c / FG_COARSE_SPAN_X) - int2(2 * FG_COARSE_RANGE_X, 2 * FG_COARSE_RANGE);
		int2 back = total >> 1;          // floor(D/2)
		int2 fwd = total - back;         // ceil(D/2)
		// Prefer small motion when the match is about as good
		float sad = 0.01 * float(abs(total.x) + abs(total.y));
		for (int y = -1; y <= FG_BLOCK; y++) {
			int rp = (y - back.y + 1 + FG_COARSE_RANGE) * FG_COARSE_TILE_X + 1 + FG_COARSE_RANGE_X - back.x;
			int rc = (y + fwd.y + 1 + FG_COARSE_RANGE) * FG_COARSE_TILE_X + 1 + FG_COARSE_RANGE_X + fwd.x;
			for (int x = -1; x <= FG_BLOCK; x++) sad += abs(tp[rp + x] - tc[rc + x]);
		}
		if (sad < best) {
			best = sad;
			bestI = c;
		}
	}
	bestCost[tid] = best;
	bestIndex[tid] = bestI;
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (tid != 0) return;
	for (uint i = 1; i < FG_COARSE_THREADS; i++) {
		if (bestCost[i] < best || (bestCost[i] == best && bestIndex[i] < bestI)) {
			best = bestCost[i];
			bestI = bestIndex[i];
		}
	}
	int2 total = int2(bestI % FG_COARSE_SPAN_X, bestI / FG_COARSE_SPAN_X) - int2(2 * FG_COARSE_RANGE_X, 2 * FG_COARSE_RANGE);
	// z: how well it matched, mean difference per pixel (without the small-motion preference)
	float match = (best - 0.01 * float(abs(total.x) + abs(total.y))) / float((FG_BLOCK + 2) * (FG_BLOCK + 2));
	field.write(float4(float2(total) * 4.0, match, 0), block);
}

// The frame's dominant motion (camera pan, map scroll): the coarse vector with
// the most others close to it, averaged with them. Up to FG_GLOBAL_SAMPLES
// coarse vectors, evenly spread. Writes (motion, share of vectors that agree).
constant int FG_GLOBAL_SAMPLES = 512;
constant float FG_GLOBAL_NEAR = 4.5;  // full px: one coarse step either way counts as the same motion

constant float FG_MATCH_GOOD = 0.025;  // coarse block's mean difference that counts as a match

kernel void fg_global(texture2d<float, access::read> coarse [[texture(0)]],
                      texture2d<float, access::write> out [[texture(1)]],
                      texture2d<float, access::read> rawCoarse [[texture(2)]],
                      texture2d<float, access::read> prevE [[texture(3)]],
                      texture2d<float, access::read> currE [[texture(4)]],
                      constant FGParams &p [[buffer(0)]],
                      uint tid [[thread_index_in_threadgroup]],
                      uint threads [[threads_per_threadgroup]]) {
	threadgroup float2 v[FG_GLOBAL_SAMPLES];
	threadgroup int support[FG_GLOBAL_SAMPLES];
	threadgroup bool matched[FG_GLOBAL_SAMPLES];
	threadgroup float2 detail[FG_GLOBAL_SAMPLES];  // each frame's edge strength in the block
	int n = p.coarseCount.x * p.coarseCount.y;
	int stride = (n + FG_GLOBAL_SAMPLES - 1) / FG_GLOBAL_SAMPLES;
	int m = (n + stride - 1) / stride;
	for (int i = int(tid); i < m; i += int(threads)) {
		int k = i * stride;
		uint2 c = uint2(k % p.coarseCount.x, k / p.coarseCount.x);
		v[i] = coarse.read(c).xy;
		matched[i] = rawCoarse.read(c).z < FG_MATCH_GOOD;
		float2 e = 0;
		int2 o = int2(c) * FG_BLOCK;
		for (int y = 0; y < FG_BLOCK; y++) {
			for (int x = 0; x < FG_BLOCK; x++) {
				int2 q = o + int2(x, y);
				e.x += abs(fg_read(prevE, q + int2(1, 0)) - fg_read(prevE, q))
				     + abs(fg_read(prevE, q + int2(0, 1)) - fg_read(prevE, q));
				e.y += abs(fg_read(currE, q + int2(1, 0)) - fg_read(currE, q))
				     + abs(fg_read(currE, q + int2(0, 1)) - fg_read(currE, q));
			}
		}
		detail[i] = e;
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	for (int i = int(tid); i < m; i += int(threads)) {
		int s = 0;
		for (int j = 0; j < m; j++) {
			float2 d = abs(v[i] - v[j]);
			s += d.x + d.y <= FG_GLOBAL_NEAR ? 1 : 0;
		}
		support[i] = s;
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (tid != 0) return;
	int best = 0;
	for (int i = 1; i < m; i++) {
		if (support[i] > support[best]) best = i;
	}
	float2 sum = 0;
	float2 detailSum = 0;
	int good = 0;
	for (int j = 0; j < m; j++) {
		float2 d = abs(v[best] - v[j]);
		if (d.x + d.y <= FG_GLOBAL_NEAR) sum += v[j];
		good += matched[j] ? 1 : 0;
		detailSum += detail[j];
	}
	// w: how far motion can be trusted for this pair, 0...1. Low across a
	// cut (little of the frame matches) or a fade from or to a plain screen
	// (one frame has much less detail than the other: every vector fits the
	// plain one, so patches pick bits of the other frame from anywhere)
	detailSum /= float(m * FG_BLOCK * FG_BLOCK);
	float ratio = (min(detailSum.x, detailSum.y) + 0.002) / (max(detailSum.x, detailSum.y) + 0.002);
	float share = float(good) / float(m);
	float trust = min(smoothstep(0.3, 0.6, share), smoothstep(0.3, 0.6, ratio));
	out.write(float4(sum / float(support[best]), float(support[best]) / float(m), trust), uint2(0));
}

// `prior` is last pair's motion for this block. Flat areas (pole and trunk
// interiors) and repeating detail (windows) match many vectors about equally,
// so without it the pick changes every frame and the edges flicker. A small
// pull towards last frame's answer keeps those picks steady.
//
// `dominant` is the frame's dominant motion (x, y, share of the frame that
// agreed). Things drawn on their own layer (map labels and icons) move a
// little differently from what's under them, so they don't match well under
// any vector, and one that lands them on plain ground can win, which erases
// them. Vectors far from the dominant motion pay for it, by how much of the
// frame agreed: only a clearly better match (a car, its own textured object)
// gets one.
constant float FG_DOMINANT_FREE = 8.0;  // full px of half motion from the dominant motion that's free
constant float FG_DOMINANT_PULL = 0.02;

static float fg_fine_cost(texture2d<float, access::sample> prev, texture2d<float, access::sample> curr,
                          float2 base, float2 d, float2 prior, float4 dominant, float2 quarterSize) {
	float2 dq = d * 0.25;
	float2 inv = 1.0 / quarterSize;
	float2 dp = abs(d - prior);
	float2 dd = abs(d - dominant.xy);
	float sad = 0.002 * (abs(d.x) + abs(d.y)) + 0.006 * (dp.x + dp.y)
	          + FG_DOMINANT_PULL * dominant.z * max(0.0, dd.x + dd.y - FG_DOMINANT_FREE);
	for (int y = -1; y <= FG_BLOCK; y++) {
		for (int x = -1; x <= FG_BLOCK; x++) {
			float2 q = base + float2(x, y) + 0.5;
			sad += abs(prev.sample(fgLinear, (q - dq) * inv).r - curr.sample(fgLinear, (q + dq) * inv).r);
		}
	}
	return sad;
}

// Whether `v` is one of the first `n` vectors in `tried`: neighbouring coarse
// blocks often agree, and the same vector again costs the same, so can't win
static bool fg_tried(thread const float2 *tried, int n, float2 v) {
	bool seen = false;
	for (int k = 0; k < n; k++) seen = seen || all(v == tried[k]);
	return seen;
}

constant int FG_PATCH_LO = -2, FG_PATCH_HI = 6;  // patch rows/columns around each 4x4 block (8x8)
constant int FG_LK_STEPS = 3;
constant float FG_LK_PRIOR = 2e-4;  // pull towards last pair's vector: wins in flat areas only
constant float FG_LK_HUBER = 0.04;  // residuals above this count less (edges of other objects)

// Patches every 16 full px, each 32 px square, on the 1/4 images: pick the best
// of zero, last pair's vector and the nearby coarse vectors, then Lucas-Kanade
// (Gauss-Newton) steps on both frames at once: moving the previous frame's
// sample back and the current one's forward by the same amount, solve for the
// change that makes them match. That lands on sub-pixel motion directly,
// where a step search only gets as close as its smallest step and can stop on
// a different near-tie each frame.
kernel void fg_fine(texture2d<float, access::sample> prev [[texture(0)]],
                    texture2d<float, access::sample> curr [[texture(1)]],
                    texture2d<float, access::read> coarse [[texture(2)]],
                    texture2d<float, access::write> field [[texture(3)]],
                    texture2d<float, access::read> priorField [[texture(4)]],
                    texture2d<float, access::sample> prevG [[texture(5)]],
                    texture2d<float, access::sample> currG [[texture(6)]],
                    texture2d<float, access::read> globalNow [[texture(7)]],
                    texture2d<float, access::read> globalPrev [[texture(8)]],
                    constant FGParams &p [[buffer(0)]],
                    constant int &hasPrior [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
	if (int(gid.x) >= p.fineCount.x || int(gid.y) >= p.fineCount.y) return;
	float2 base = float2(gid) * float(FG_BLOCK);
	int2 cell = int2(gid) / 2;
	// Last pair's motion, moved on by however much the dominant motion
	// changed: when a pan speeds up or turns (scrolling the map), flat areas
	// would otherwise keep last pair's motion and drag what's on them (map
	// icons) the wrong way. Only when most of the frame agreed on it both times.
	float4 gNow = globalNow.read(uint2(0)), gPrev = globalPrev.read(uint2(0));
	float2 prior = 0;
	if (hasPrior) {
		prior = priorField.read(gid).xy;
		if (gNow.z > 0.25 && gPrev.z > 0.25) prior += gNow.xy - gPrev.xy;
	}

	float2 bestD = float2(0);
	float best = fg_fine_cost(prev, curr, base, bestD, prior, gNow, p.quarterSize);
	float2 tried[12];
	int nTried = 0;
	tried[nTried++] = float2(0);
	if (hasPrior && !fg_tried(tried, nTried, prior)) {
		tried[nTried++] = prior;
		float cost = fg_fine_cost(prev, curr, base, prior, prior, gNow, p.quarterSize);
		if (cost < best) {
			best = cost;
			bestD = prior;
		}
	}
	if (!fg_tried(tried, nTried, gNow.xy)) {
		tried[nTried++] = gNow.xy;
		float cost = fg_fine_cost(prev, curr, base, gNow.xy, prior, gNow, p.quarterSize);
		if (cost < best) {
			best = cost;
			bestD = gNow.xy;
		}
	}
	for (int cy = -1; cy <= 1; cy++) {
		for (int cx = -1; cx <= 1; cx++) {
			int2 c = clamp(cell + int2(cx, cy), int2(0), p.coarseCount - 1);
			float2 d = coarse.read(uint2(c)).xy;
			if (fg_tried(tried, nTried, d)) continue;
			tried[nTried++] = d;
			float cost = fg_fine_cost(prev, curr, base, d, prior, gNow, p.quarterSize);
			if (cost < best) {
				best = cost;
				bestD = d;
			}
		}
	}

	// Gauss-Newton on r = curr(q + d/4) - prev(q - d/4), d in full px
	float2 inv = 1.0 / p.quarterSize;
	float2 anchor = hasPrior ? prior : bestD;
	float2 d = bestD;
	for (int step = 0; step < FG_LK_STEPS; step++) {
		float2 dq = d * 0.25;
		float3 h = 0;  // xx, xy, yy
		float2 g = 0;
		for (int y = FG_PATCH_LO; y < FG_PATCH_HI; y++) {
			for (int x = FG_PATCH_LO; x < FG_PATCH_HI; x++) {
				float2 q = base + float2(x, y) + 0.5;
				float3 a = prevG.sample(fgLinear, (q - dq) * inv).rgb;
				float3 b = currG.sample(fgLinear, (q + dq) * inv).rgb;
				float r = b.x - a.x;
				float2 j = (a.yz + b.yz) * 0.25;
				float w = FG_LK_HUBER / max(FG_LK_HUBER, abs(r));
				h += w * float3(j.x * j.x, j.x * j.y, j.y * j.y);
				g += w * j * r;
			}
		}
		h.xz += FG_LK_PRIOR;
		g += FG_LK_PRIOR * (d - anchor);
		float det = h.x * h.z - h.y * h.y;
		float2 delta = -float2(h.z * g.x - h.y * g.y, h.x * g.y - h.y * g.x) / det;
		d += clamp(delta, -4.0, 4.0);
	}
	// Keep it only if it's really better: a step can run off on a patch
	// that's mostly another moving object
	if (fg_fine_cost(prev, curr, base, d, prior, gNow, p.quarterSize) < best) bestD = d;
	field.write(float4(bestD, 0, 0), gid);
}

// 3x3 vector median: removes lone wrong vectors without blurring motion edges
static float2 fg_median(texture2d<float, access::read> src, int2 at, int2 count) {
	float2 v[9];
	int n = 0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			int2 c = clamp(at + int2(x, y), int2(0), count - 1);
			v[n++] = src.read(uint2(c)).xy;
		}
	}
	float best = INFINITY;
	float2 bestV = v[4];
	for (int i = 0; i < 9; i++) {
		float dist = 0;
		for (int j = 0; j < 9; j++) {
			float2 diff = abs(v[i] - v[j]);
			dist += diff.x + diff.y;
		}
		if (dist < best) {
			best = dist;
			bestV = v[i];
		}
	}
	return bestV;
}

kernel void fg_smooth(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant FGParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
	if (int(gid.x) >= p.fineCount.x || int(gid.y) >= p.fineCount.y) return;
	dst.write(float4(fg_median(src, int2(gid), p.fineCount), 0, 0), gid);
}

// The same on the coarse search: in flat areas (sky, plain parts of the map)
// the search can lock on to anything, and one stray vector there is enough
// for a patch to pick it
kernel void fg_smooth_coarse(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant FGParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
	if (int(gid.x) >= p.coarseCount.x || int(gid.y) >= p.coarseCount.y) return;
	dst.write(float4(fg_median(src, int2(gid), p.coarseCount), 0, 0), gid);
}

// One vector per 1/4 pixel from the patches around it: each patch's vector,
// weighted by how close the pixel is to the patch centre and by how well that
// vector fits at this pixel. So where two objects meet, each side takes the
// motion of the patches that fit it, and the map stays smooth elsewhere.
kernel void fg_densify(texture2d<float, access::sample> prev [[texture(0)]],
                       texture2d<float, access::sample> curr [[texture(1)]],
                       texture2d<float, access::read> field [[texture(2)]],
                       texture2d<float, access::write> flow [[texture(3)]],
                       constant FGParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= flow.get_width() || gid.y >= flow.get_height()) return;
	float2 inv = 1.0 / p.quarterSize;
	float2 q = float2(gid) + 0.5;
	// Patch centres are at 4i + 2
	int2 i0 = int2(floor((q - 2.0) * 0.25));
	float2 sum = 0;
	float wsum = 0;
	for (int y = -1; y <= 2; y++) {
		for (int x = -1; x <= 2; x++) {
			int2 i = i0 + int2(x, y);
			float2 tent = max(0.0, 1.0 - abs(q - (float2(i) * 4.0 + 2.0)) / 6.0);
			float sw = tent.x * tent.y;
			if (sw <= 0) continue;
			float2 d = field.read(uint2(clamp(i, int2(0), p.fineCount - 1))).xy;
			float2 dq = d * 0.25;
			float e = abs(prev.sample(fgLinear, (q - dq) * inv).r - curr.sample(fgLinear, (q + dq) * inv).r)
			        + abs(prev.sample(fgLinear, (q - dq - 0.5) * inv).r - curr.sample(fgLinear, (q + dq - 0.5) * inv).r)
			        + abs(prev.sample(fgLinear, (q - dq + 0.5) * inv).r - curr.sample(fgLinear, (q + dq + 0.5) * inv).r);
			float w = sw / (e * (1.0 / 3.0) + 0.01);
			sum += w * d;
			wsum += w;
		}
	}
	flow.write(float4(wsum > 0 ? sum / wsum : float2(0), 0, 0), gid);
}

// MARK: - Synthesis

constant int FG_CANDIDATES = 6;
constant float FG_EDGE_REACH = 8.0;  // full px: where the other side of an edge's motion is read
constant float FG_EDGE_COST = 0.025; // cost given to a candidate that runs off the screen edge

// Synthesis quality level, one pipeline each (FrameGenerator.levels). Lower
// levels are cheaper and are used when the GPU can't keep up:
// 0: each pixel judges its candidates on three taps per frame (about 3x3)
// 1: one tap per frame: the whole generator takes about a third less time,
//    a little less steady on thin detail
// 2: each 2x2 block of pixels shares one choice, judged on its four pixels:
//    about 40% less time, edges between motions land on 2 px steps
constant int fgSynthLevel [[function_constant(0)]];

// Whether a luma sample at `q` is off the screen, where the sampler only
// repeats the border
static bool fg_offscreen(float2 q, constant FGParams &p) {
	return any(q < -0.5) || any(q > p.lumaSize + 0.5);
}

// Candidate weights for the pixel at full-size luma position `pos`: the motion
// map here, the motion map a little way off in each direction (at an object's
// edge, one of those has the pure motion of each side) and zero motion.
//
// Thin detail (power lines, fences, text) is where this goes wrong: if the
// motion is a little off, blending the two frames gives two faint copies of a
// line, and real frames show one sharp copy, so it flickers. So:
// - each candidate is judged on a small patch, not one pixel, so the choice
//   doesn't jump around from frame to frame;
// - weights are relative to the best candidate, so the best one wins clearly
//   even when nothing matches well;
// - where the two frames disagree along a candidate, it uses the current
//   frame's pixel alone instead of a half-and-half mix.
struct FGCandidates {
	float2 d[FG_CANDIDATES];
	float w[FG_CANDIDATES];
	float agree[FG_CANDIDATES];  // 1 where the two frames match along the candidate, 0 where they don't
	float y[FG_CANDIDATES];      // luma along each candidate
	float cur[FG_CANDIDATES];    // the newer frame's luma alone along each candidate
	// 1 where the candidate's newer-frame sample is off-screen (the thing is
	// leaving), so only the older frame has it; -1 where the older one is
	// off-screen (entering); 0 otherwise
	float only[FG_CANDIDATES];
	// How well the best candidate fits, 0...1. Where nothing fits (wheels
	// spinning, things changing shape), any blend lands detail in a different
	// wrong place each frame, which flickers. There we use the newer frame
	// alone, still moved along the motion so a wheel stays on its car.
	float confidence;
};

static FGCandidates fg_candidates(texture2d<float, access::sample> prevY, texture2d<float, access::sample> currY,
                                  texture2d<float, access::sample> flow, float2 pos, constant FGParams &p,
                                  bool threeTaps) {
	FGCandidates c;
	float2 inv = 1.0 / p.lumaSize;
	const float2 offsets[4] = { float2(FG_EDGE_REACH, 0), float2(-FG_EDGE_REACH, 0),
	                            float2(0, FG_EDGE_REACH), float2(0, -FG_EDGE_REACH) };
	float cost[FG_CANDIDATES];
	float bw[FG_CANDIDATES];
	float minCost = INFINITY;
	for (int j = 0; j < FG_CANDIDATES; j++) {
		if (j == 0) {
			c.d[j] = flow.sample(fgLinear, pos * inv).xy;
			bw[j] = 1.0;
		} else if (j < 5) {
			c.d[j] = flow.sample(fgLinear, (pos + offsets[j - 1]) * inv).xy;
			bw[j] = 0.15;
		} else {
			// Zero motion: keeps HUDs and other static overlays in place
			c.d[j] = float2(0);
			bw[j] = 0.3;
		}
		float2 pa = pos - c.d[j];
		float2 pb = pos + c.d[j];
		float a = prevY.sample(fgLinear, pa * inv).r;
		float b = currY.sample(fgLinear, pb * inv).r;
		if (threeTaps) {
			// Two more taps between pixels, each the average of a 2x2: covers about 3x3
			float a1 = prevY.sample(fgLinear, (pa - 0.5) * inv).r;
			float b1 = currY.sample(fgLinear, (pb - 0.5) * inv).r;
			float a2 = prevY.sample(fgLinear, (pa + 0.5) * inv).r;
			float b2 = currY.sample(fgLinear, (pb + 0.5) * inv).r;
			cost[j] = (abs(a - b) + abs(a1 - b1) + abs(a2 - b2)) * (1.0 / 3.0);
		} else {
			cost[j] = abs(a - b);
		}

		c.agree[j] = exp(-abs(a - b) * 20.0);
		// Mostly the newer frame even where they agree: a 50/50 mix smooths out
		// compression noise, so generated frames look cleaner than real ones and
		// soft areas like shadows shimmer as the two alternate
		c.y[j] = mix(b, mix(a, b, FG_NEWER_WEIGHT), c.agree[j]);
		c.cur[j] = b;

		// At the screen edge one end of the motion can land off-screen, where
		// the sampler just repeats the border column. Comparing against that
		// says "no match" and the object (a pole leaving the screen) breaks
		// up into smeared border pixels. Use the frame that still has it, at
		// a fixed middling cost since there's nothing to check it against.
		bool outA = fg_offscreen(pa, p);
		bool outB = fg_offscreen(pb, p);
		c.only[j] = 0;
		if (outA != outB) {
			c.only[j] = outB ? 1.0 : -1.0;
			c.y[j] = c.cur[j] = outB ? a : b;
			c.agree[j] = 0;
			cost[j] = FG_EDGE_COST;
		}
		minCost = min(minCost, cost[j]);
	}
	for (int j = 0; j < FG_CANDIDATES; j++) {
		c.w[j] = bw[j] * exp(-(cost[j] - minCost) * 60.0) + 1e-6;
	}
	c.confidence = 1.0 - smoothstep(0.03, 0.09, minCost);
	return c;
}


// Cut or fade (see fg_global): a plain half-and-half mix in place, which is
// what a fade's halfway point is anyway. `trust` (0...1) is how much of the
// motion-compensated result to use instead.
static float fg_fade_luma(texture2d<float, access::sample> prevY, texture2d<float, access::sample> currY,
                          float2 pos, float generated, float trust, constant FGParams &p) {
	if (trust >= 1) return generated;
	float2 inv = 1.0 / p.lumaSize;
	float fade = 0.5 * (prevY.sample(fgLinear, pos * inv).r + currY.sample(fgLinear, pos * inv).r);
	return mix(fade, generated, trust);
}

// Luma and chroma in one pass (4:2:0 only), one thread per chroma pixel. The
// 2x2 luma pixels under it are made first, and the chroma reuses their
// candidate motion and weights instead of judging the candidates again.
kernel void fg_synth(texture2d<float, access::sample> prevY [[texture(0)]],
                     texture2d<float, access::sample> currY [[texture(1)]],
                     texture2d<float, access::sample> prevC [[texture(2)]],
                     texture2d<float, access::sample> currC [[texture(3)]],
                     texture2d<float, access::sample> flow [[texture(4)]],
                     texture2d<float, access::write> outY [[texture(5)]],
                     texture2d<float, access::write> outC [[texture(6)]],
                     texture2d<float, access::read> global [[texture(7)]],
                     constant FGParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
	if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
	uint2 base = gid * 2;
	uint2 lumaMax = uint2(outY.get_width(), outY.get_height());
	float2 posC = float2(gid) + 0.5;
	float2 scale = p.lumaSize / p.chromaSize;
	float2 invC = 1.0 / p.chromaSize;
	float trust = global.read(uint2(0)).w;
	float2 fadeC = 0.5 * (prevC.sample(fgLinear, posC * invC).rg + currC.sample(fgLinear, posC * invC).rg);
	if (trust <= 0) {
		float2 inv = 1.0 / p.lumaSize;
		for (int k = 0; k < 4; k++) {
			uint2 lp = base + uint2(k & 1, k >> 1);
			if (any(lp >= lumaMax)) continue;
			float2 pos = float2(lp) + 0.5;
			outY.write(float4(0.5 * (prevY.sample(fgLinear, pos * inv).r + currY.sample(fgLinear, pos * inv).r)), lp);
		}
		outC.write(float4(fadeC, 0, 0), gid);
		return;
	}

	// Per candidate, for the chroma: motion (luma px), weight (normalised per
	// luma pixel and summed), agreement (weighted the same way) and which
	// frame alone has it at the screen edge (see fg_candidates)
	float2 d[FG_CANDIDATES];
	float w[FG_CANDIDATES], agree[FG_CANDIDATES], only[FG_CANDIDATES];
	float confidence = 0;

	if (fgSynthLevel < 2) {
		for (int j = 0; j < FG_CANDIDATES; j++) {
			d[j] = 0;
			w[j] = 0;
			agree[j] = 0;
		}
		float n = 0;
		for (int k = 0; k < 4; k++) {
			uint2 lp = base + uint2(k & 1, k >> 1);
			if (any(lp >= lumaMax)) continue;
			float2 pos = float2(lp) + 0.5;
			FGCandidates c = fg_candidates(prevY, currY, flow, pos, p, fgSynthLevel == 0);
			float sum = 0, held = 0, wsum = 0;
			for (int j = 0; j < FG_CANDIDATES; j++) {
				sum += c.w[j] * c.y[j];
				held += c.w[j] * c.cur[j];
				wsum += c.w[j];
			}
			outY.write(float4(fg_fade_luma(prevY, currY, pos, mix(held, sum, c.confidence) / wsum, trust, p)), lp);
			for (int j = 0; j < FG_CANDIDATES; j++) {
				d[j] += c.d[j];
				w[j] += c.w[j] / wsum;
				agree[j] += c.agree[j] * c.w[j] / wsum;
			}
			confidence += c.confidence;
			n += 1;
		}
		float2 posL = posC * scale;
		for (int j = 0; j < FG_CANDIDATES; j++) {
			d[j] /= n;
			agree[j] /= w[j];
			bool outA = fg_offscreen(posL - d[j], p), outB = fg_offscreen(posL + d[j], p);
			only[j] = outA == outB ? 0.0 : (outB ? 1.0 : -1.0);
		}
		confidence /= n;
	} else {
		// One choice for the 2x2 block, judged on its four pixels: the
		// samples that make the picture are the ones compared
		float2 inv = 1.0 / p.lumaSize;
		float2 posQ = float2(base) + 1.0;
		const float2 offsets[4] = { float2(FG_EDGE_REACH, 0), float2(-FG_EDGE_REACH, 0),
		                            float2(0, FG_EDGE_REACH), float2(0, -FG_EDGE_REACH) };
		float cost[FG_CANDIDATES];
		float a[FG_CANDIDATES * 4], b[FG_CANDIDATES * 4];
		float minCost = INFINITY;
		for (int j = 0; j < FG_CANDIDATES; j++) {
			if (j == 0) {
				d[j] = flow.sample(fgLinear, posQ * inv).xy;
				w[j] = 1.0;
			} else if (j < 5) {
				d[j] = flow.sample(fgLinear, (posQ + offsets[j - 1]) * inv).xy;
				w[j] = 0.15;
			} else {
				d[j] = float2(0);
				w[j] = 0.3;
			}
			float sad = 0;
			for (int k = 0; k < 4; k++) {
				float2 pos = float2(base + uint2(k & 1, k >> 1)) + 0.5;
				float av = prevY.sample(fgLinear, (pos - d[j]) * inv).r;
				float bv = currY.sample(fgLinear, (pos + d[j]) * inv).r;
				a[j * 4 + k] = av;
				b[j * 4 + k] = bv;
				sad += abs(av - bv);
			}
			cost[j] = sad * 0.25;
			bool outA = fg_offscreen(posQ - d[j], p), outB = fg_offscreen(posQ + d[j], p);
			only[j] = 0;
			if (outA != outB) {
				only[j] = outB ? 1.0 : -1.0;
				for (int k = 0; k < 4; k++) {
					if (outB) b[j * 4 + k] = a[j * 4 + k];
					else a[j * 4 + k] = b[j * 4 + k];
				}
				cost[j] = FG_EDGE_COST;
			}
			minCost = min(minCost, cost[j]);
		}
		float wsum = 0;
		for (int j = 0; j < FG_CANDIDATES; j++) {
			w[j] = w[j] * exp(-(cost[j] - minCost) * 60.0) + 1e-6;
			wsum += w[j];
			agree[j] = 0;
		}
		confidence = 1.0 - smoothstep(0.03, 0.09, minCost);
		for (int k = 0; k < 4; k++) {
			float sum = 0, held = 0;
			for (int j = 0; j < FG_CANDIDATES; j++) {
				float av = a[j * 4 + k], bv = b[j * 4 + k];
				float ag = exp(-abs(av - bv) * 20.0);
				agree[j] += ag * 0.25;
				sum += w[j] * mix(bv, mix(av, bv, FG_NEWER_WEIGHT), ag);
				held += w[j] * bv;
			}
			uint2 lp = base + uint2(k & 1, k >> 1);
			if (any(lp >= lumaMax)) continue;
			float2 pos = float2(lp) + 0.5;
			outY.write(float4(fg_fade_luma(prevY, currY, pos, mix(held, sum, confidence) / wsum, trust, p)), lp);
		}
	}

	float2 sum = 0, held = 0;
	float wsum = 0;
	for (int j = 0; j < FG_CANDIDATES; j++) {
		float2 dc = d[j] / scale;
		float2 a = prevC.sample(fgLinear, (posC - dc) * invC).rg;
		float2 b = currC.sample(fgLinear, (posC + dc) * invC).rg;
		float ag = agree[j];
		if (only[j] > 0) b = a;
		else if (only[j] < 0) a = b;
		if (only[j] != 0) ag = 0;
		sum += w[j] * mix(b, mix(a, b, FG_NEWER_WEIGHT), ag);
		held += w[j] * b;
		wsum += w[j];
	}
	float2 chroma = mix(held, sum, confidence) / wsum;
	outC.write(float4(trust >= 1 ? chroma : mix(fadeC, chroma, trust), 0, 0), gid);
}
