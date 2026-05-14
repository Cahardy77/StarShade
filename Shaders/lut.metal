// Name: Warm Color Grading
// Description: Warm cinematic LUT with lifted shadows and boosted saturation

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    float4 color = tex.sample(smp, in.texCoord);
    float3 rgb = color.rgb;

    // Lift-Gamma-Gain color grading
    float3 lift = float3(0.02, 0.01, -0.01);
    float3 gamma = float3(1.0, 0.98, 0.95);
    float3 gain = float3(1.02, 1.0, 0.97);

    rgb = gain * (rgb + lift * (1.0 - rgb));
    rgb = pow(max(rgb, float3(0.0)), gamma);

    // S-curve contrast
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);
    rgb = mix(color.rgb, rgb, 0.4);

    // Saturation boost
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, 1.15);

    return float4(saturate(rgb), 1.0);
}
