#include <metal_stdlib>
using namespace metal;

// Must match RenderUniforms in MetalRenderer.swift
struct RenderUniforms {
	float2 ndcScale;   // size of the picture quad in NDC (1,1 = full target)
	float2 uvOrigin;   // texture-space crop (zoom mode)
	float2 uvSize;
	float2 lumaSize;   // luma texture size in texels
	int matrix;        // 0 = BT.709, 1 = BT.2020
	int transferMode;  // 0 = passthrough, 1 = SDR on PQ target, 2 = PQ on SDR target
	int bicubic;       // Catmull-Rom luma upscaling
	int fullRange;
};

struct VertexOut {
	float4 position [[position]];
	float2 uv;
};

vertex VertexOut stream_vertex(uint vid [[vertex_id]], constant RenderUniforms &u [[buffer(0)]]) {
	// triangle strip quad
	float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
	float2 uv01 = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
	VertexOut out;
	out.position = float4(corner * u.ndcScale, 0.0, 1.0);
	out.uv = u.uvOrigin + uv01 * u.uvSize;
	return out;
}

// 9-tap Catmull-Rom using bilinear filtering (sharper than bilinear for the
// 1080p -> ~2670 px upscale on the Duo's inner screen).
static float sample_catmull_rom(texture2d<float> tex, sampler s, float2 uv, float2 texSize) {
	float2 samplePos = uv * texSize;
	float2 texPos1 = floor(samplePos - 0.5) + 0.5;
	float2 f = samplePos - texPos1;
	float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	float2 w3 = f * f * (-0.5 + 0.5 * f);
	float2 w12 = w1 + w2;
	float2 offset12 = w2 / w12;
	float2 tp0 = (texPos1 - 1.0) / texSize;
	float2 tp3 = (texPos1 + 2.0) / texSize;
	float2 tp12 = (texPos1 + offset12) / texSize;

	float r = 0.0;
	r += tex.sample(s, float2(tp0.x,  tp0.y)).r  * w0.x  * w0.y;
	r += tex.sample(s, float2(tp12.x, tp0.y)).r  * w12.x * w0.y;
	r += tex.sample(s, float2(tp3.x,  tp0.y)).r  * w3.x  * w0.y;
	r += tex.sample(s, float2(tp0.x,  tp12.y)).r * w0.x  * w12.y;
	r += tex.sample(s, float2(tp12.x, tp12.y)).r * w12.x * w12.y;
	r += tex.sample(s, float2(tp3.x,  tp12.y)).r * w3.x  * w12.y;
	r += tex.sample(s, float2(tp0.x,  tp3.y)).r  * w0.x  * w3.y;
	r += tex.sample(s, float2(tp12.x, tp3.y)).r  * w12.x * w3.y;
	r += tex.sample(s, float2(tp3.x,  tp3.y)).r  * w3.x  * w3.y;
	return r;
}

// SMPTE ST 2084 (PQ)
constant float PQ_M1 = 0.1593017578125;
constant float PQ_M2 = 78.84375;
constant float PQ_C1 = 0.8359375;
constant float PQ_C2 = 18.8515625;
constant float PQ_C3 = 18.6875;

static float3 pq_to_linear(float3 e) { // -> nits / 10000
	float3 p = pow(max(e, 0.0), 1.0 / PQ_M2);
	return pow(max(p - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * p), 1.0 / PQ_M1);
}

static float3 linear_to_pq(float3 l) { // l in nits / 10000
	float3 p = pow(max(l, 0.0), PQ_M1);
	return pow((PQ_C1 + PQ_C2 * p) / (1.0 + PQ_C3 * p), PQ_M2);
}

fragment float4 stream_fragment(VertexOut in [[stage_in]],
                                texture2d<float> lumaTex [[texture(0)]],
                                texture2d<float> chromaTex [[texture(1)]],
                                constant RenderUniforms &u [[buffer(0)]]) {
	constexpr sampler s(filter::linear, address::clamp_to_edge);

	float y = u.bicubic ? sample_catmull_rom(lumaTex, s, in.uv, u.lumaSize) : lumaTex.sample(s, in.uv).r;
	float2 c = chromaTex.sample(s, in.uv).rg;

	if (!u.fullRange) {
		y = (y - 16.0 / 255.0) * (255.0 / 219.0);
		c = (c - 128.0 / 255.0) * (255.0 / 224.0);
	} else {
		c = c - 0.5;
	}

	float3 rgb;
	if (u.matrix == 1) { // BT.2020 non-constant luminance
		rgb = float3(y + 1.4746 * c.y,
		             y - 0.16455 * c.x - 0.57135 * c.y,
		             y + 1.8814 * c.x);
	} else {             // BT.709
		rgb = float3(y + 1.5748 * c.y,
		             y - 0.1873 * c.x - 0.4681 * c.y,
		             y + 1.8556 * c.x);
	}
	rgb = saturate(rgb);

	if (u.transferMode == 1) {
		// SDR frame on an HDR (PQ) layer: BT.709 gamma -> linear -> BT.2020 -> PQ at 203 nits reference white
		float3 lin = pow(rgb, 2.4);
		const float3x3 bt709_to_2020 = float3x3(float3(0.6274, 0.0691, 0.0164),
		                                        float3(0.3293, 0.9195, 0.0880),
		                                        float3(0.0433, 0.0114, 0.8956));
		lin = bt709_to_2020 * lin;
		rgb = linear_to_pq(lin * (203.0 / 10000.0));
	} else if (u.transferMode == 2) {
		// PQ frame on an SDR layer: simple Reinhard tone map, no gamut mapping
		float3 nits = pq_to_linear(rgb) * 10000.0;
		float3 v = nits / 203.0;
		v = v / (1.0 + v * 0.25);
		rgb = pow(saturate(v), 1.0 / 2.4);
	} else if (u.transferMode == 3) {
		// HDR screenshot to SDR PNG: roll off highlights by luminance and map
		// the linear BT.2020 primaries to sRGB (the same primaries as BT.709).
		float3 linear = pq_to_linear(rgb) * (10000.0 / 203.0);
		float luminance = dot(linear, float3(0.2627, 0.6780, 0.0593));
		if (luminance > 0.65) {
			float mapped = 1.0 - 0.35 * exp((0.65 - luminance) / 0.35);
			linear *= mapped / luminance;
		}
		const float3x3 bt2020_to_709 = float3x3(float3( 1.6605, -0.1246, -0.0182),
		                                        float3(-0.5876,  1.1329, -0.1006),
		                                        float3(-0.0728, -0.0083,  1.1187));
		linear = saturate(bt2020_to_709 * linear);
		rgb = select(1.055 * pow(linear, 1.0 / 2.4) - 0.055, 12.92 * linear, linear <= 0.0031308);
	}

	return float4(rgb, 1.0);
}

fragment float4 stream_scaled_fragment(VertexOut in [[stage_in]],
                                       texture2d<float, access::read> color [[texture(0)]],
                                       constant int2 &origin [[buffer(0)]]) {
	return float4(color.read(uint2(int2(in.position.xy) - origin)).rgb, 1.0);
}

// MetalFX 4K: shrink onto the screen by averaging four taps across each screen pixel's footprint
fragment float4 stream_downsample_fragment(VertexOut in [[stage_in]], texture2d<float> color [[texture(0)]]) {
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float2 dx = dfdx(in.uv) * 0.25;
	float2 dy = dfdy(in.uv) * 0.25;
	float3 c = color.sample(s, in.uv - dx - dy).rgb + color.sample(s, in.uv + dx - dy).rgb
	         + color.sample(s, in.uv - dx + dy).rgb + color.sample(s, in.uv + dx + dy).rgb;
	return float4(c * 0.25, 1.0);
}
