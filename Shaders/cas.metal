// Name: CAS Sharpening
// Description: AMD FidelityFX Contrast Adaptive Sharpening

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant ShaderParams &params [[buffer(0)]]) {
    float2 uv = in.texCoord;
    float2 texel = float2(params.texelWidth, params.texelHeight);

    float3 a = tex.sample(smp, uv + float2(-texel.x, -texel.y)).rgb;
    float3 b = tex.sample(smp, uv + float2( 0.0,    -texel.y)).rgb;
    float3 c = tex.sample(smp, uv + float2( texel.x, -texel.y)).rgb;
    float3 d = tex.sample(smp, uv + float2(-texel.x,  0.0   )).rgb;
    float3 e = tex.sample(smp, uv).rgb;
    float3 f = tex.sample(smp, uv + float2( texel.x,  0.0   )).rgb;
    float3 g = tex.sample(smp, uv + float2(-texel.x,  texel.y)).rgb;
    float3 h = tex.sample(smp, uv + float2( 0.0,     texel.y)).rgb;
    float3 i = tex.sample(smp, uv + float2( texel.x,  texel.y)).rgb;

    float3 mnRGB = min(min(min(d, e), min(f, b)), h);
    float3 mxRGB = max(max(max(d, e), max(f, b)), h);
    mnRGB = min(min(mnRGB, min(a, c)), min(g, i));
    mxRGB = max(max(mxRGB, max(a, c)), max(g, i));

    float3 ampRGB = clamp(min(mnRGB, 2.0 - mxRGB) / mxRGB, float3(0.0), float3(1.0));
    ampRGB = sqrt(ampRGB);
    float peak = -3.0 * params.sharpness + 8.0;
    float3 wRGB = ampRGB / peak;
    float3 result = ((b + d + f + h) * wRGB + e) / (1.0 + 4.0 * wRGB);

    return float4(saturate(result), 1.0);
}
