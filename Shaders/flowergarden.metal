// Name: Flower Garden
// Description: AdaptiveSharpen + DPX + HSLShift + Lightroom from FlowerGarden preset

// Adaptive Sharpen (curve_height=0.07)
float3 applyAdaptiveSharpen(texture2d<float> tex, sampler smp, float2 uv, float2 texel, float3 center) {
    constexpr float curve_height = 0.07;

    float3 n = tex.sample(smp, uv + float2(0, -texel.y)).rgb;
    float3 s = tex.sample(smp, uv + float2(0,  texel.y)).rgb;
    float3 e = tex.sample(smp, uv + float2( texel.x, 0)).rgb;
    float3 w = tex.sample(smp, uv + float2(-texel.x, 0)).rgb;

    float3 lumaW = float3(0.2126, 0.7152, 0.0722);
    float lumaC = dot(center, lumaW);
    float lumaN = dot(n, lumaW);
    float lumaS = dot(s, lumaW);
    float lumaE = dot(e, lumaW);
    float lumaW2 = dot(w, lumaW);

    float edge = abs(lumaN + lumaS + lumaE + lumaW2 - 4.0 * lumaC);
    float sharpAmount = curve_height * (1.0 - saturate(edge * 10.0));

    float3 blur = (n + s + e + w) * 0.25;
    float3 sharp = center + (center - blur) * sharpAmount * 10.0;

    return saturate(sharp);
}

// DPX cinematic color (Strength=0.108)
float3 applyDPX(float3 color) {
    const float3 RGB_Curve = float3(10.545, 8.0, 8.0);
    const float3 RGB_C = float3(0.36, 0.36, 0.34);
    constexpr float DPX_Strength = 0.108;

    float3 cin = clamp(color, 0.001, 1.0);
    float luma = dot(cin, float3(0.299, 0.587, 0.114));
    float3 warm = float3(luma * 1.02, luma * 1.0, luma * 0.97);
    float3 result = mix(warm, cin, 0.85);

    return mix(color, saturate(result), DPX_Strength);
}

// HSL Shift — per-hue color targets
float3 applyHSLShift(float3 color) {
    const float3 hueRed     = float3(0.682, 0.208, 0.220);
    const float3 hueOrange  = float3(0.843, 0.553, 0.333);
    const float3 hueYellow  = float3(0.796, 0.686, 0.345);
    const float3 hueGreen   = float3(0.392, 0.702, 0.263);
    const float3 hueCyan    = float3(0.325, 0.788, 0.718);

    float cmax = max(color.r, max(color.g, color.b));
    float cmin = min(color.r, min(color.g, color.b));
    float delta = cmax - cmin;
    float luma = (cmax + cmin) * 0.5;
    float sat = delta / max(cmax, 0.001);

    float weight = sat * (1.0 - abs(luma * 2.0 - 1.0)) * 0.08;

    float3 shift = float3(0.0);
    if (delta > 0.01) {
        if (color.r >= color.g && color.r >= color.b) {
            shift = mix(hueRed, hueOrange, saturate((color.g - color.b) / delta));
        } else if (color.g >= color.r && color.g >= color.b) {
            shift = mix(hueGreen, hueYellow, saturate((color.r - color.b) / delta));
        } else {
            shift = hueCyan;
        }
    }

    return mix(color, shift * luma * 2.0, weight);
}

// qUINT Lightroom — selective color grading
float3 applyLightroom(float3 color) {
    float3 rgb = color;
    float cmax = max(rgb.r, max(rgb.g, rgb.b));
    float cmin = min(rgb.r, min(rgb.g, rgb.b));
    float delta = cmax - cmin;

    if (delta > 0.01) {
        float hue;
        if (cmax == rgb.r) {
            hue = fmod((rgb.g - rgb.b) / delta, 6.0) / 6.0;
        } else if (cmax == rgb.g) {
            hue = ((rgb.b - rgb.r) / delta + 2.0) / 6.0;
        } else {
            hue = ((rgb.r - rgb.g) / delta + 4.0) / 6.0;
        }
        if (hue < 0.0) hue += 1.0;

        float sat = delta / max(cmax, 0.001);

        float redW = saturate(1.0 - abs(hue) * 12.0) + saturate(1.0 - abs(hue - 1.0) * 12.0);
        redW = min(redW, 1.0) * sat;
        float orangeW = saturate(1.0 - abs(hue - 0.08) * 12.0) * sat;
        float yellowW = saturate(1.0 - abs(hue - 0.16) * 12.0) * sat;
        float greenW = saturate(1.0 - abs(hue - 0.33) * 12.0) * sat;

        float exposure = redW * -0.001 + orangeW * 0.015 + yellowW * 0.092;
        rgb *= 1.0 + exposure;

        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float satAdj = redW * 0.067 + orangeW * 0.048 + yellowW * 0.011 + greenW * 0.017;
        rgb = mix(float3(luma), rgb, 1.0 + satAdj);
    }

    return saturate(rgb);
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant ShaderParams &params [[buffer(0)]]) {
    float2 uv = in.texCoord;
    float2 texel = float2(params.texelWidth, params.texelHeight);
    float intensity = params.sharpness;

    float3 color = tex.sample(smp, uv).rgb;
    color = applyAdaptiveSharpen(tex, smp, uv, texel, color);
    color = applyDPX(color);
    color = applyHSLShift(color);
    color = applyLightroom(color);

    float3 original = tex.sample(smp, uv).rgb;
    color = mix(original, color, intensity);

    return float4(saturate(color), 1.0);
}
