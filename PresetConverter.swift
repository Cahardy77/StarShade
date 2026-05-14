// PresetConverter.swift
// Converts ReShade-format .txt preset files (INI format) into Metal shader source code.
// Supports single-pass, non-depth-dependent effects only.

import Foundation

class PresetConverter {

    // MARK: - Data Types

    struct ParsedPreset {
        let name: String
        let enabledTechniques: [(name: String, file: String)]
        let sections: [String: [String: String]]
    }

    struct ConvertedShader {
        let metalSource: String
        let displayName: String
        let description: String
        let needsParams: Bool
    }

    // MARK: - INI Parser

    static func parsePreset(content: String, fileName: String) -> ParsedPreset {
        var techniques: [(name: String, file: String)] = []
        var sections: [String: [String: String]] = [:]
        var currentSection: String? = nil

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            // Section header [filename.fx]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                if sections[currentSection!] == nil {
                    sections[currentSection!] = [:]
                }
                continue
            }

            // Key=Value
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if currentSection == nil {
                if key == "Techniques" {
                    techniques = parseTechniqueList(value)
                }
            } else {
                sections[currentSection!]?[key] = value
            }
        }

        // If no Techniques line, infer from sections
        if techniques.isEmpty {
            for section in sections.keys.sorted() {
                if let techName = inferTechniqueName(from: section) {
                    techniques.append((name: techName, file: section))
                }
            }
            if !techniques.isEmpty {
                print("  ⚠️  No Techniques= line found, inferred \(techniques.count) effects from sections")
            }
        }

        let name = fileName.hasSuffix(".txt") ? String(fileName.dropLast(4)) : fileName
        return ParsedPreset(name: name, enabledTechniques: techniques, sections: sections)
    }

    private static func parseTechniqueList(_ value: String) -> [(name: String, file: String)] {
        // Some presets have Techniques= and TechniqueSorting= on the same line
        // separated by a space. Truncate at " TechniqueSorting=" if present.
        var cleanValue = value
        if let range = cleanValue.range(of: " TechniqueSorting=", options: .caseInsensitive) {
            cleanValue = String(cleanValue[..<range.lowerBound])
        }
        // Also handle tab-separated
        if let range = cleanValue.range(of: "\tTechniqueSorting=", options: .caseInsensitive) {
            cleanValue = String(cleanValue[..<range.lowerBound])
        }

        var result: [(name: String, file: String)] = []
        var seen = Set<String>()
        for entry in cleanValue.components(separatedBy: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: "@")
            if parts.count == 2 {
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let file = parts[1].trimmingCharacters(in: .whitespaces)
                let key = "\(name)@\(file)"
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append((name: name, file: file))
                }
            }
        }
        return result
    }

    private static func inferTechniqueName(from section: String) -> String? {
        let map: [String: String] = [
            "DPX.fx": "DPX",
            "AdaptiveSharpen.fx": "AdaptiveSharpen",
            "FineSharp.fx": "Mode2",
            "HSLShift.fx": "HSLShift",
            "qUINT_lightroom.fx": "Lightroom",
            "PD80_04_Selective_Color.fx": "prod80_04_SelectiveColor",
            "PD80_04_Selective_Color_v2.fx": "prod80_04_SelectiveColor_v2",
            "MinimalColorGrading.fx": "MinimalColorGrading",
            "Sepia.fx": "Tint",
            "PD80_04_Contrast_Brightness_Saturation.fx": "prod80_04_ContrastBrightnessSaturation",
            "Vignette.fx": "Vignette",
            "Vibrance.fx": "Vibrance",
        ]
        return map[section]
    }

    // MARK: - Parameter Helpers

    static func floatParam(_ params: [String: String], _ key: String, _ fallback: Float) -> Float {
        guard let str = params[key] else { return fallback }
        // Handle locale issues (some presets use comma as decimal)
        let normalized = str.replacingOccurrences(of: ",", with: ".")
        return Float(normalized) ?? fallback
    }

    static func float3Param(_ params: [String: String], _ key: String, _ fallback: (Float, Float, Float)) -> (Float, Float, Float) {
        guard let str = params[key] else { return fallback }
        let parts = str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            return (Float(parts[0]) ?? fallback.0, Float(parts[1]) ?? fallback.1, Float(parts[2]) ?? fallback.2)
        }
        return fallback
    }

    static func fmt(_ v: Float) -> String {
        return String(format: "%.6f", v)
    }

    // MARK: - Technique Classification

    static let depthDependentTechniques: Set<String> = [
        "MXAO", "PPFXSSDO", "ADOF", "CinematicDOF", "Monocular_Cues",
        "AdaptiveFog", "CanvasFog", "DepthHaze", "HeightFog",
        "StageDepth", "StageDepthPlus", "AmbientLight",
        "PCGI_One", "RadiantGI", "SSR", "Pirate_DOF", "Pirate_GI",
        "LightDoF_AutoFocus", "LightDoF_Far", "LightDoF_Near",
        "Emphasize", "DepthDarkness", "DepthAlpha", "DepthSharpen",
        "FocalDOF", "MagicDOF", "RingDOF", "GP65CJ042DOF",
        "MatsoDOF", "MartyMcFlyDOF", "Information_SD", "Information",
        "SuperDepth3D", "SuperDepth3D_VR", "DirectionalDepthBlur",
        "DepthSharpenconstDof", "Flashlight", "DepthDarkening",
    ]

    static let multiPassTechniques: Set<String> = [
        "MagicBloom", "NeoBloom", "Bloom", "BloomAndLensFlares",
        "Blooming_HDR", "prod80_02_Bloom", "PPFXBloom", "Pirate_Bloom",
        "Bessel_Bloom", "ArcaneBloom", "GaussianBloom", "SimpleBloom",
        "OrtonBloom", "prod80_02_Cinetools_LUT", "prod80_02_Bonus_LUT_pack",
        "LocalContrastCS", "SMAA", "CMAA_2", "TAA", "NFAA",
        "Normal_Filter_Anti_Aliasing", "MartysMods_AntiAliasing",
        "Debanding", "prod80_01A_RT_Correct_Contrast",
        "prod80_01B_RT_Correct_Color", "Clarity", "Clarity2",
        "FXAA", "BilateralCS", "Smart_Sharp", "HDR",
    ]

    // MARK: - Convert Preset to Metal

    static func convert(preset: ParsedPreset) -> ConvertedShader {
        var helpers: [String] = []
        var calls: [String] = []
        var needsTexSamples = false
        var supportedNames: [String] = []
        var skippedDepth: [String] = []
        var skippedMultiPass: [String] = []
        var skippedUnknown: [String] = []
        var usedHandlers = Set<String>()  // Prevent duplicate function definitions

        for tech in preset.enabledTechniques {
            let techName = tech.name
            let fileName = tech.file

            if depthDependentTechniques.contains(techName) {
                skippedDepth.append(techName)
                continue
            }
            if multiPassTechniques.contains(techName) {
                skippedMultiPass.append(techName)
                continue
            }

            let params = preset.sections[fileName] ?? [:]

            // Skip if we've already generated this handler (prevents duplicate Metal functions)
            let handlerKey = techName
            if usedHandlers.contains(handlerKey) { continue }
            usedHandlers.insert(handlerKey)

            switch techName {

            case "DPX":
                let (h, c) = genDPX(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("DPX")

            case "AdaptiveSharpen":
                let (h, c) = genAdaptiveSharpen(params)
                helpers.append(h); calls.append(c)
                needsTexSamples = true
                supportedNames.append("AdaptiveSharpen")

            case "Mode1", "Mode2", "Mode3":
                let (h, c) = genFineSharp(params)
                helpers.append(h); calls.append(c)
                needsTexSamples = true
                supportedNames.append("FineSharp")

            case "HSLShift":
                let (h, c) = genHSLShift(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("HSLShift")

            case "Lightroom":
                let (h, c) = genLightroom(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("Lightroom")

            case "prod80_04_SelectiveColor":
                let (h, c) = genSelectiveColorV1(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("SelectiveColor")

            case "prod80_04_SelectiveColor_v2":
                let (h, c) = genSelectiveColorV2(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("SelectiveColor v2")

            case "MinimalColorGrading":
                let (h, c) = genMinimalColorGrading(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("ColorGrading")

            case "Tint":
                let (h, c) = genSepia(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("Tint")

            case "prod80_04_ContrastBrightnessSaturation":
                let (h, c) = genContrastBrightnessSat(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("Contrast/Brightness")

            case "ContrastAdaptiveSharpen":
                let (h, c) = genCAS(params)
                helpers.append(h); calls.append(c)
                needsTexSamples = true
                supportedNames.append("CAS")

            case "Vignette":
                let (h, _) = genVignette(params)
                helpers.append(h)
                calls.append("    color = applyVignette(color, uv);")
                supportedNames.append("Vignette")

            case "ArtisticVignette":
                let (h, _) = genArtisticVignette(params)
                helpers.append(h)
                calls.append("    color = applyArtisticVignette(color, uv);")
                supportedNames.append("ArtisticVignette")

            case "Vibrance":
                let (h, c) = genVibrance(params)
                helpers.append(h); calls.append(c)
                supportedNames.append("Vibrance")

            default:
                skippedUnknown.append(techName)
            }
        }

        // Build description
        var descParts: [String] = []
        if !supportedNames.isEmpty { descParts.append(supportedNames.joined(separator: " + ")) }
        if !skippedDepth.isEmpty { descParts.append("(\(skippedDepth.count) depth-based skipped)") }
        if !skippedMultiPass.isEmpty { descParts.append("(\(skippedMultiPass.count) multi-pass skipped)") }
        let description = descParts.isEmpty ? "No convertible effects" : descParts.joined(separator: " ")

        // Log conversion results
        print("  ✅ Converted: \(supportedNames.joined(separator: ", "))")
        if !skippedDepth.isEmpty { print("  ⏭  Skipped (depth): \(skippedDepth.joined(separator: ", "))") }
        if !skippedMultiPass.isEmpty { print("  ⏭  Skipped (multi-pass): \(skippedMultiPass.joined(separator: ", "))") }
        if !skippedUnknown.isEmpty { print("  ⏭  Skipped (unknown): \(skippedUnknown.joined(separator: ", "))") }

        // Handle no-effects case
        if calls.isEmpty {
            let source = """
            // Name: \(preset.name)
            // Description: \(description)

            fragment float4 fragment_main(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler smp [[sampler(0)]]) {
                return tex.sample(smp, in.texCoord);
            }
            """
            return ConvertedShader(metalSource: source, displayName: preset.name, description: description, needsParams: false)
        }

        // Assemble shader
        let needsParams = needsTexSamples
        var source = "// Name: \(preset.name)\n"
        source += "// Description: \(description)\n\n"

        for helper in helpers {
            source += helper + "\n\n"
        }

        // Fragment main
        if needsParams {
            source += "fragment float4 fragment_main(VertexOut in [[stage_in]],\n"
            source += "                              texture2d<float> tex [[texture(0)]],\n"
            source += "                              sampler smp [[sampler(0)]],\n"
            source += "                              constant ShaderParams &params [[buffer(0)]]) {\n"
            source += "    float2 uv = in.texCoord;\n"
            source += "    float2 texel = float2(params.texelWidth, params.texelHeight);\n"
            source += "    float intensity = params.sharpness;\n\n"
            source += "    float3 color = tex.sample(smp, uv).rgb;\n\n"
        } else {
            source += "fragment float4 fragment_main(VertexOut in [[stage_in]],\n"
            source += "                              texture2d<float> tex [[texture(0)]],\n"
            source += "                              sampler smp [[sampler(0)]]) {\n"
            source += "    float2 uv = in.texCoord;\n\n"
            source += "    float3 color = tex.sample(smp, uv).rgb;\n\n"
        }

        for call in calls {
            source += call + "\n"
        }

        if needsParams {
            source += "\n    float3 original = tex.sample(smp, uv).rgb;\n"
            source += "    color = mix(original, color, intensity);\n"
        }

        source += "\n    return float4(saturate(color), 1.0);\n"
        source += "}\n"

        return ConvertedShader(metalSource: source, displayName: preset.name, description: description, needsParams: needsParams)
    }

    // MARK: - Effect Generators

    // Each returns (helperFunction, callStatement)

    static func genDPX(_ p: [String: String]) -> (String, String) {
        let strength = floatParam(p, "Strength", 0.2)
        let contrast = floatParam(p, "Contrast", 0.1)
        let saturation = floatParam(p, "Saturation", 3.0)
        let colorfulness = floatParam(p, "Colorfulness", 2.5)
        let rc = float3Param(p, "RGB_Curve", (8.0, 8.0, 8.0))
        let rgbc = float3Param(p, "RGB_C", (0.36, 0.36, 0.34))

        let helper = """
        float3 applyDPX(float3 color) {
            constexpr float DPX_Strength = \(fmt(strength));
            constexpr float DPX_Contrast = \(fmt(contrast));
            constexpr float DPX_Saturation = \(fmt(saturation));
            constexpr float DPX_Colorfulness = \(fmt(colorfulness));
            const float3 RGB_Curve = float3(\(fmt(rc.0)), \(fmt(rc.1)), \(fmt(rc.2)));
            const float3 RGB_C = float3(\(fmt(rgbc.0)), \(fmt(rgbc.1)), \(fmt(rgbc.2)));

            float3 B = color;
            B = B * (1.0 - DPX_Contrast) + (0.5 * DPX_Contrast);

            float3 Btemp = 1.0 / (1.0 + exp(RGB_Curve / 2.0));
            B = ((1.0 / (1.0 + exp(-RGB_Curve * (B - RGB_C)))) / (-2.0 * Btemp + 1.0))
                + (-Btemp / (-2.0 * Btemp + 1.0));

            float value = max(max(B.r, B.g), B.b);
            float3 c = B / max(value, 0.001);
            c = pow(abs(c), 1.0 / DPX_Saturation);
            float3 c0 = c * value;

            float luma = dot(c0, float3(0.299, 0.587, 0.114));
            c0 = mix(float3(luma), c0, DPX_Colorfulness);

            return mix(color, saturate(c0), DPX_Strength);
        }
        """
        return (helper, "    color = applyDPX(color);")
    }

    static func genAdaptiveSharpen(_ p: [String: String]) -> (String, String) {
        let curveHeight = floatParam(p, "curve_height", 0.07)

        let helper = """
        float3 applyAdaptiveSharpen(texture2d<float> tex, sampler smp, float2 uv, float2 texel, float3 center) {
            constexpr float curve_height = \(fmt(curveHeight));

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
        """
        return (helper, "    color = applyAdaptiveSharpen(tex, smp, uv, texel, color);")
    }

    static func genFineSharp(_ p: [String: String]) -> (String, String) {
        let sstr = floatParam(p, "sstr", 0.384)
        let lstr = floatParam(p, "lstr", 1.490)

        let helper = """
        float3 applyFineSharp(texture2d<float> tex, sampler smp, float2 uv, float2 texel, float3 center) {
            constexpr float sstr = \(fmt(sstr));
            constexpr float lstr = \(fmt(lstr));

            float3 n = tex.sample(smp, uv + float2(0, -texel.y)).rgb;
            float3 s = tex.sample(smp, uv + float2(0,  texel.y)).rgb;
            float3 e = tex.sample(smp, uv + float2( texel.x, 0)).rgb;
            float3 w = tex.sample(smp, uv + float2(-texel.x, 0)).rgb;

            float3 blur = (n + s + e + w) * 0.25;
            float3 diff = center - blur;
            float strength = sstr * lstr;
            float3 sharp = center + diff * strength;

            return saturate(sharp);
        }
        """
        return (helper, "    color = applyFineSharp(tex, smp, uv, texel, color);")
    }

    static func genHSLShift(_ p: [String: String]) -> (String, String) {
        let hueRed = float3Param(p, "HUERed", (0.682, 0.208, 0.220))
        let hueOrange = float3Param(p, "HUEOrange", (0.843, 0.553, 0.333))
        let hueYellow = float3Param(p, "HUEYellow", (0.796, 0.686, 0.345))
        let hueGreen = float3Param(p, "HUEGreen", (0.392, 0.702, 0.263))
        let hueCyan = float3Param(p, "HUEcyan", (0.325, 0.788, 0.718))

        let helper = """
        float3 applyHSLShift(float3 color) {
            const float3 hueRed     = float3(\(fmt(hueRed.0)), \(fmt(hueRed.1)), \(fmt(hueRed.2)));
            const float3 hueOrange  = float3(\(fmt(hueOrange.0)), \(fmt(hueOrange.1)), \(fmt(hueOrange.2)));
            const float3 hueYellow  = float3(\(fmt(hueYellow.0)), \(fmt(hueYellow.1)), \(fmt(hueYellow.2)));
            const float3 hueGreen   = float3(\(fmt(hueGreen.0)), \(fmt(hueGreen.1)), \(fmt(hueGreen.2)));
            const float3 hueCyan    = float3(\(fmt(hueCyan.0)), \(fmt(hueCyan.1)), \(fmt(hueCyan.2)));

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
        """
        return (helper, "    color = applyHSLShift(color);")
    }

    static func genLightroom(_ p: [String: String]) -> (String, String) {
        let redExp = floatParam(p, "LIGHTROOM_RED_EXPOSURE", 0.0)
        let redSat = floatParam(p, "LIGHTROOM_RED_SATURATION", 0.0)
        let orangeExp = floatParam(p, "LIGHTROOM_ORANGE_EXPOSURE", 0.0)
        let orangeSat = floatParam(p, "LIGHTROOM_ORANGE_SATURATION", 0.0)
        let yellowExp = floatParam(p, "LIGHTROOM_YELLOW_EXPOSURE", 0.0)
        let yellowSat = floatParam(p, "LIGHTROOM_YELLOW_SATURATION", 0.0)
        let greenExp = floatParam(p, "LIGHTROOM_GREEN_EXPOSURE", 0.0)
        let greenSat = floatParam(p, "LIGHTROOM_GREEN_SATURATION", 0.0)
        let blueExp = floatParam(p, "LIGHTROOM_BLUE_EXPOSURE", 0.0)
        let blueSat = floatParam(p, "LIGHTROOM_BLUE_SATURATION", 0.0)
        let aquaExp = floatParam(p, "LIGHTROOM_AQUA_EXPOSURE", 0.0)
        let aquaSat = floatParam(p, "LIGHTROOM_AQUA_SATURATION", 0.0)
        let magentaExp = floatParam(p, "LIGHTROOM_MAGENTA_EXPOSURE", 0.0)
        let magentaSat = floatParam(p, "LIGHTROOM_MAGENTA_SATURATION", 0.0)
        let globalExp = floatParam(p, "LIGHTROOM_GLOBAL_EXPOSURE", 0.0)
        let globalCon = floatParam(p, "LIGHTROOM_GLOBAL_CONTRAST", 0.0)
        let globalSat = floatParam(p, "LIGHTROOM_GLOBAL_SATURATION", 0.0)
        let globalVib = floatParam(p, "LIGHTROOM_GLOBAL_VIBRANCE", 0.0)
        let globalTemp = floatParam(p, "LIGHTROOM_GLOBAL_TEMPERATURE", 0.0)

        let helper = """
        float3 applyLightroom(float3 color) {
            float3 rgb = color;

            // Global adjustments
            rgb *= 1.0 + \(fmt(globalExp));
            float gLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            rgb = mix(float3(gLuma), rgb, 1.0 + \(fmt(globalSat)));

            // Global contrast
            rgb = mix(float3(0.5), rgb, 1.0 + \(fmt(globalCon)));

            // Global vibrance (smart saturation)
            float maxC = max(rgb.r, max(rgb.g, rgb.b));
            float minC = min(rgb.r, min(rgb.g, rgb.b));
            float vibSat = 1.0 - (maxC - minC);
            float vibLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            rgb = mix(float3(vibLuma), rgb, 1.0 + \(fmt(globalVib)) * vibSat);

            // Temperature (warm/cool shift)
            rgb.r *= 1.0 + \(fmt(globalTemp)) * 0.1;
            rgb.b *= 1.0 - \(fmt(globalTemp)) * 0.1;

            // Per-hue adjustments
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
                float orangeW = saturate(1.0 - abs(hue - 0.083) * 12.0) * sat;
                float yellowW = saturate(1.0 - abs(hue - 0.167) * 12.0) * sat;
                float greenW = saturate(1.0 - abs(hue - 0.333) * 12.0) * sat;
                float aquaW = saturate(1.0 - abs(hue - 0.500) * 12.0) * sat;
                float blueW = saturate(1.0 - abs(hue - 0.667) * 12.0) * sat;
                float magentaW = saturate(1.0 - abs(hue - 0.833) * 12.0) * sat;

                float exposure = redW * \(fmt(redExp))
                    + orangeW * \(fmt(orangeExp))
                    + yellowW * \(fmt(yellowExp))
                    + greenW * \(fmt(greenExp))
                    + aquaW * \(fmt(aquaExp))
                    + blueW * \(fmt(blueExp))
                    + magentaW * \(fmt(magentaExp));
                rgb *= 1.0 + exposure;

                float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
                float satAdj = redW * \(fmt(redSat))
                    + orangeW * \(fmt(orangeSat))
                    + yellowW * \(fmt(yellowSat))
                    + greenW * \(fmt(greenSat))
                    + aquaW * \(fmt(aquaSat))
                    + blueW * \(fmt(blueSat))
                    + magentaW * \(fmt(magentaSat));
                rgb = mix(float3(luma), rgb, 1.0 + satAdj);
            }

            return saturate(rgb);
        }
        """
        return (helper, "    color = applyLightroom(color);")
    }

    static func genSelectiveColorV1(_ p: [String: String]) -> (String, String) {
        // PD80 Selective Color v1: 6 hue ranges + neutrals/whites/blacks
        // Per-range: _cya, _mag, _yel, _bla, _sat, _vib
        let relative = floatParam(p, "corr_method", 1.0) > 0.5

        func adj(_ prefix: String, _ suffix: String, _ fallback: Float = 0.0) -> Float {
            return floatParam(p, "\(prefix)_adj_\(suffix)", fallback)
        }

        let helper = """
        float3 applySelectiveColorV1(float3 color) {
            float cmax = max(color.r, max(color.g, color.b));
            float cmin = min(color.r, min(color.g, color.b));
            float delta = cmax - cmin;
            if (delta < 0.01) return color;

            float3 rgb = color;
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
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));

            // Hue range weights (6 ranges)
            float rW = (saturate(1.0 - abs(hue) * 6.0) + saturate(1.0 - abs(hue - 1.0) * 6.0));
            rW = min(rW, 1.0) * sat;
            float yW = saturate(1.0 - abs(hue - 0.167) * 6.0) * sat;
            float gW = saturate(1.0 - abs(hue - 0.333) * 6.0) * sat;
            float cW = saturate(1.0 - abs(hue - 0.500) * 6.0) * sat;
            float bW = saturate(1.0 - abs(hue - 0.667) * 6.0) * sat;
            float mW = saturate(1.0 - abs(hue - 0.833) * 6.0) * sat;

            \(relative ? "// Relative correction mode" : "// Absolute correction mode")
            \(relative ? "float3 mult = rgb;" : "float3 mult = float3(1.0);")

            // CMY adjustments: cyan reduces red, magenta reduces green, yellow reduces blue
            rgb.r -= rW * \(fmt(adj("r","cya"))) * mult.r + yW * \(fmt(adj("y","cya"))) * mult.r + gW * \(fmt(adj("g","cya"))) * mult.r;
            rgb.r -= cW * \(fmt(adj("c","cya"))) * mult.r + bW * \(fmt(adj("b","cya"))) * mult.r + mW * \(fmt(adj("m","cya"))) * mult.r;

            rgb.g -= rW * \(fmt(adj("r","mag"))) * mult.g + yW * \(fmt(adj("y","mag"))) * mult.g + gW * \(fmt(adj("g","mag"))) * mult.g;
            rgb.g -= cW * \(fmt(adj("c","mag"))) * mult.g + bW * \(fmt(adj("b","mag"))) * mult.g + mW * \(fmt(adj("m","mag"))) * mult.g;

            rgb.b -= rW * \(fmt(adj("r","yel"))) * mult.b + yW * \(fmt(adj("y","yel"))) * mult.b + gW * \(fmt(adj("g","yel"))) * mult.b;
            rgb.b -= cW * \(fmt(adj("c","yel"))) * mult.b + bW * \(fmt(adj("b","yel"))) * mult.b + mW * \(fmt(adj("m","yel"))) * mult.b;

            // Black adjustment
            float blkAdj = rW * \(fmt(adj("r","bla"))) + yW * \(fmt(adj("y","bla"))) + gW * \(fmt(adj("g","bla")));
            blkAdj += cW * \(fmt(adj("c","bla"))) + bW * \(fmt(adj("b","bla"))) + mW * \(fmt(adj("m","bla")));
            rgb *= 1.0 - blkAdj * 0.5;

            // Saturation adjustment
            float satLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float satAdj = rW * \(fmt(adj("r","sat"))) + yW * \(fmt(adj("y","sat"))) + gW * \(fmt(adj("g","sat")));
            satAdj += cW * \(fmt(adj("c","sat"))) + bW * \(fmt(adj("b","sat"))) + mW * \(fmt(adj("m","sat")));
            rgb = mix(float3(satLuma), rgb, 1.0 + satAdj);

            return saturate(rgb);
        }
        """
        return (helper, "    color = applySelectiveColorV1(color);")
    }

    static func genSelectiveColorV2(_ p: [String: String]) -> (String, String) {
        // PD80 Selective Color v2: 11 hue ranges + neutrals/whites/blacks
        let relative = floatParam(p, "corr_method", 1.0) > 0.5

        func adj(_ prefix: String, _ suffix: String, _ fallback: Float = 0.0) -> Float {
            return floatParam(p, "\(prefix)_adj_\(suffix)", fallback)
        }

        let helper = """
        float3 applySelectiveColorV2(float3 color) {
            float cmax = max(color.r, max(color.g, color.b));
            float cmin = min(color.r, min(color.g, color.b));
            float delta = cmax - cmin;
            if (delta < 0.005) return color;

            float3 rgb = color;
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
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));

            // 11 hue range weights with smooth falloff
            constexpr float bw = 8.0;
            float rW = (saturate(1.0 - abs(hue) * bw) + saturate(1.0 - abs(hue - 1.0) * bw));
            rW = min(rW, 1.0) * sat;
            float oW  = saturate(1.0 - abs(hue - 0.083) * bw) * sat;
            float yW  = saturate(1.0 - abs(hue - 0.167) * bw) * sat;
            float ygW = saturate(1.0 - abs(hue - 0.208) * bw) * sat;
            float gW  = saturate(1.0 - abs(hue - 0.333) * bw) * sat;
            float gcW = saturate(1.0 - abs(hue - 0.417) * bw) * sat;
            float cW  = saturate(1.0 - abs(hue - 0.500) * bw) * sat;
            float cbW = saturate(1.0 - abs(hue - 0.583) * bw) * sat;
            float bW  = saturate(1.0 - abs(hue - 0.667) * bw) * sat;
            float bmW = saturate(1.0 - abs(hue - 0.750) * bw) * sat;
            float mrW = saturate(1.0 - abs(hue - 0.917) * bw) * sat;

            // Neutrals/whites/blacks weights
            float nW = 1.0 - sat;
            float wW = smoothstep(0.5, 1.0, luma) * (1.0 - sat * 0.5);
            float bkW = smoothstep(0.5, 0.0, luma) * (1.0 - sat * 0.5);

            \(relative ? "float3 mult = rgb;" : "float3 mult = float3(1.0);")

            // Cyan adjustment (reduces red channel)
            float cyaTotal = rW * \(fmt(adj("r","cya"))) + oW * \(fmt(adj("o","cya"))) + yW * \(fmt(adj("y","cya")))
                + ygW * \(fmt(adj("yg","cya"))) + gW * \(fmt(adj("g","cya"))) + gcW * \(fmt(adj("gc","cya")))
                + cW * \(fmt(adj("c","cya"))) + cbW * \(fmt(adj("cb","cya"))) + bW * \(fmt(adj("b","cya")))
                + bmW * \(fmt(adj("bm","cya"))) + mrW * \(fmt(adj("mr","cya")))
                + nW * \(fmt(adj("n","cya"))) + wW * \(fmt(adj("w","cya"))) + bkW * \(fmt(adj("bk","cya")));
            rgb.r -= cyaTotal * mult.r;

            // Magenta adjustment (reduces green channel)
            float magTotal = rW * \(fmt(adj("r","mag"))) + oW * \(fmt(adj("o","mag"))) + yW * \(fmt(adj("y","mag")))
                + ygW * \(fmt(adj("yg","mag"))) + gW * \(fmt(adj("g","mag"))) + gcW * \(fmt(adj("gc","mag")))
                + cW * \(fmt(adj("c","mag"))) + cbW * \(fmt(adj("cb","mag"))) + bW * \(fmt(adj("b","mag")))
                + bmW * \(fmt(adj("bm","mag"))) + mrW * \(fmt(adj("mr","mag")))
                + nW * \(fmt(adj("n","mag"))) + wW * \(fmt(adj("w","mag"))) + bkW * \(fmt(adj("bk","mag")));
            rgb.g -= magTotal * mult.g;

            // Yellow adjustment (reduces blue channel)
            float yelTotal = rW * \(fmt(adj("r","yel"))) + oW * \(fmt(adj("o","yel"))) + yW * \(fmt(adj("y","yel")))
                + ygW * \(fmt(adj("yg","yel"))) + gW * \(fmt(adj("g","yel"))) + gcW * \(fmt(adj("gc","yel")))
                + cW * \(fmt(adj("c","yel"))) + cbW * \(fmt(adj("cb","yel"))) + bW * \(fmt(adj("b","yel")))
                + bmW * \(fmt(adj("bm","yel"))) + mrW * \(fmt(adj("mr","yel")))
                + nW * \(fmt(adj("n","yel"))) + wW * \(fmt(adj("w","yel"))) + bkW * \(fmt(adj("bk","yel")));
            rgb.b -= yelTotal * mult.b;

            // Black adjustment (darkens/lightens)
            float blaTotal = rW * \(fmt(adj("r","bla"))) + oW * \(fmt(adj("o","bla"))) + yW * \(fmt(adj("y","bla")))
                + ygW * \(fmt(adj("yg","bla"))) + gW * \(fmt(adj("g","bla"))) + gcW * \(fmt(adj("gc","bla")))
                + cW * \(fmt(adj("c","bla"))) + cbW * \(fmt(adj("cb","bla"))) + bW * \(fmt(adj("b","bla")))
                + bmW * \(fmt(adj("bm","bla"))) + mrW * \(fmt(adj("mr","bla")))
                + nW * \(fmt(adj("n","bla"))) + wW * \(fmt(adj("w","bla"))) + bkW * \(fmt(adj("bk","bla")));
            rgb *= 1.0 - blaTotal * 0.5;

            // Saturation adjustment
            float satLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float satTotal = rW * \(fmt(adj("r","sat"))) + oW * \(fmt(adj("o","sat"))) + yW * \(fmt(adj("y","sat")))
                + ygW * \(fmt(adj("yg","sat"))) + gW * \(fmt(adj("g","sat"))) + gcW * \(fmt(adj("gc","sat")))
                + cW * \(fmt(adj("c","sat"))) + cbW * \(fmt(adj("cb","sat"))) + bW * \(fmt(adj("b","sat")))
                + bmW * \(fmt(adj("bm","sat"))) + mrW * \(fmt(adj("mr","sat")))
                + nW * \(fmt(adj("n","sat"))) + wW * \(fmt(adj("w","sat"))) + bkW * \(fmt(adj("bk","sat")));
            rgb = mix(float3(satLuma), rgb, 1.0 + satTotal);

            // Lightness adjustment (v2 feature)
            float ligTotal = rW * \(fmt(adj("r","lig"))) + oW * \(fmt(adj("o","lig"))) + yW * \(fmt(adj("y","lig")))
                + ygW * \(fmt(adj("yg","lig"))) + gW * \(fmt(adj("g","lig"))) + gcW * \(fmt(adj("gc","lig")))
                + cW * \(fmt(adj("c","lig"))) + cbW * \(fmt(adj("cb","lig"))) + bW * \(fmt(adj("b","lig")))
                + bmW * \(fmt(adj("bm","lig"))) + mrW * \(fmt(adj("mr","lig")));
            rgb *= 1.0 + ligTotal;

            return saturate(rgb);
        }
        """
        return (helper, "    color = applySelectiveColorV2(color);")
    }

    static func genMinimalColorGrading(_ p: [String: String]) -> (String, String) {
        let exposure = floatParam(p, "Exposure", 0.0)
        let contrast = floatParam(p, "Contrast", 1.0)
        let saturation = floatParam(p, "Saturation", 1.0)
        let satMode = Int(floatParam(p, "SaturationMode", 0.0))
        let cf = float3Param(p, "ColorFilter", (1.0, 1.0, 1.0))

        let helper = """
        float3 applyMinimalColorGrading(float3 color) {
            float3 rgb = color;

            // Exposure
            rgb *= pow(2.0, \(fmt(exposure)));

            // Color filter
            rgb *= float3(\(fmt(cf.0)), \(fmt(cf.1)), \(fmt(cf.2)));

            // Contrast (around midpoint)
            rgb = mix(float3(0.5), rgb, \(fmt(contrast)));

            // Saturation
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            \(satMode == 2 ? "// Vibrance mode" : "// Standard saturation")
            \(satMode == 2 ?
                "float maxC = max(rgb.r, max(rgb.g, rgb.b));\n            float minC = min(rgb.r, min(rgb.g, rgb.b));\n            float vibW = 1.0 - (maxC - minC);\n            rgb = mix(float3(luma), rgb, 1.0 + (\(fmt(saturation)) - 1.0) * vibW);"
                : "rgb = mix(float3(luma), rgb, \(fmt(saturation)));")

            return saturate(rgb);
        }
        """
        return (helper, "    color = applyMinimalColorGrading(color);")
    }

    static func genSepia(_ p: [String: String]) -> (String, String) {
        let strength = floatParam(p, "Strength", 0.58)
        let tint = float3Param(p, "Tint", (0.55, 0.43, 0.20))

        let helper = """
        float3 applySepia(float3 color) {
            constexpr float strength = \(fmt(strength));
            const float3 tint = float3(\(fmt(tint.0)), \(fmt(tint.1)), \(fmt(tint.2)));

            float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
            float3 sepia = luma * tint;
            return mix(color, sepia, strength);
        }
        """
        return (helper, "    color = applySepia(color);")
    }

    static func genContrastBrightnessSat(_ p: [String: String]) -> (String, String) {
        let brightness = floatParam(p, "brightness", 0.0)
        let contrast = floatParam(p, "contrast", 0.0)
        let exposure = floatParam(p, "exposureN", 0.0)
        let saturation = floatParam(p, "saturation", 0.0)
        let vibrance = floatParam(p, "vibrance", 0.0)
        let tint = floatParam(p, "tint", 0.0)

        let helper = """
        float3 applyContrastBrightnessSat(float3 color) {
            float3 rgb = color;

            // Exposure
            rgb *= pow(2.0, \(fmt(exposure)));

            // Brightness
            rgb += \(fmt(brightness));

            // Contrast
            rgb = mix(float3(0.5), rgb, 1.0 + \(fmt(contrast)));

            // Tint (shift green-magenta)
            rgb.g += \(fmt(tint)) * 0.05;

            // Saturation
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            rgb = mix(float3(luma), rgb, 1.0 + \(fmt(saturation)));

            // Vibrance
            float maxC = max(rgb.r, max(rgb.g, rgb.b));
            float minC = min(rgb.r, min(rgb.g, rgb.b));
            float vibW = 1.0 - (maxC - minC);
            float vibLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            rgb = mix(float3(vibLuma), rgb, 1.0 + \(fmt(vibrance)) * vibW);

            return saturate(rgb);
        }
        """
        return (helper, "    color = applyContrastBrightnessSat(color);")
    }

    static func genCAS(_ p: [String: String]) -> (String, String) {
        let helper = """
        float3 applyCAS(texture2d<float> tex, sampler smp, float2 uv, float2 texel, float sharpness) {
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
            float peak = -3.0 * sharpness + 8.0;
            float3 wRGB = ampRGB / peak;
            float3 result = ((b + d + f + h) * wRGB + e) / (1.0 + 4.0 * wRGB);

            return saturate(result);
        }
        """
        return (helper, "    color = applyCAS(tex, smp, uv, texel, intensity);")
    }

    static func genVignette(_ p: [String: String]) -> (String, String) {
        let amount = floatParam(p, "Amount", 1.0)
        let radius = floatParam(p, "Radius", 2.0)
        let ratio = floatParam(p, "Ratio", 1.0)
        let slope = floatParam(p, "Slope", 2.0)
        let center = float3Param(p, "Center", (0.5, 0.5, 0.0))

        let helper = """
        float3 applyVignette(float3 color, float2 uv) {
            constexpr float amount = \(fmt(amount));
            constexpr float radius = \(fmt(radius));
            constexpr float ratio = \(fmt(ratio));
            constexpr float slope = \(fmt(slope));
            float2 center = float2(\(fmt(center.0)), \(fmt(center.1)));

            float2 coord = (uv - center) * float2(1.0, 1.0 / max(ratio, 0.001));
            float dist = length(coord) / radius;
            float vignette = pow(saturate(1.0 - dist), slope);
            return color * mix(1.0, vignette, abs(amount));
        }
        """
        return (helper, "")
    }

    static func genArtisticVignette(_ p: [String: String]) -> (String, String) {
        let se = float3Param(p, "VignetteStartEnd", (0.27, 1.56, 0.0))
        let vc = float3Param(p, "VignetteColor", (0.0, 0.0, 0.0))

        let helper = """
        float3 applyArtisticVignette(float3 color, float2 uv) {
            float2 coord = uv - 0.5;
            float dist = length(coord) * 2.0;
            float vignette = smoothstep(\(fmt(se.0)), \(fmt(se.1)), dist);
            float3 vigColor = float3(\(fmt(vc.0)), \(fmt(vc.1)), \(fmt(vc.2)));
            return mix(color, vigColor, vignette);
        }
        """
        return (helper, "")
    }

    static func genVibrance(_ p: [String: String]) -> (String, String) {
        let vibrance = floatParam(p, "Vibrance", 0.15)

        let helper = """
        float3 applyVibrance(float3 color) {
            float maxC = max(color.r, max(color.g, color.b));
            float minC = min(color.r, min(color.g, color.b));
            float sat = maxC - minC;
            float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
            float weight = 1.0 - sat;
            return mix(float3(luma), color, 1.0 + \(fmt(vibrance)) * weight);
        }
        """
        return (helper, "    color = applyVibrance(color);")
    }
}
