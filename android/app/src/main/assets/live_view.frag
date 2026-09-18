#version 300 es

precision highp float;

uniform sampler2D uImage;
uniform highp sampler3D uLut;
uniform vec2 uTexel;
uniform vec3 uLutDomainMin;
uniform vec3 uLutDomainMax;
uniform float uLutIntensity;
uniform float uZebraThreshold;
uniform float uPeakingThreshold;
uniform float uOpacity;
uniform int uHasLut;
uniform int uZebra;
uniform int uPeaking;
uniform int uMirror;

in vec2 textureCoordinate;
out vec4 fragmentColor;

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec2 sourceCoordinate(vec2 coordinate) {
    float x = uMirror == 1 ? 1.0 - coordinate.x : coordinate.x;
    return vec2(x, 1.0 - coordinate.y);
}

void main() {
    vec2 coordinate = sourceCoordinate(textureCoordinate);
    vec4 source = texture(uImage, coordinate);
    vec3 displayed = source.rgb;

    if (uHasLut == 1) {
        vec3 span = max(uLutDomainMax - uLutDomainMin, vec3(0.000001));
        vec3 lutCoordinate = clamp((source.rgb - uLutDomainMin) / span, 0.0, 1.0);
        displayed = mix(source.rgb, texture(uLut, lutCoordinate).rgb, clamp(uLutIntensity, 0.0, 1.0));
    }

    float sourceLuminance = luminance(source.rgb);
    if (uZebra == 1 && sourceLuminance >= uZebraThreshold) {
        float stripe = step(0.5, fract((gl_FragCoord.x + gl_FragCoord.y) / 10.0));
        displayed = mix(displayed, vec3(stripe), uOpacity);
    }

    if (uPeaking == 1) {
        float left = luminance(texture(uImage, coordinate - vec2(uTexel.x, 0.0)).rgb);
        float right = luminance(texture(uImage, coordinate + vec2(uTexel.x, 0.0)).rgb);
        float above = luminance(texture(uImage, coordinate - vec2(0.0, uTexel.y)).rgb);
        float below = luminance(texture(uImage, coordinate + vec2(0.0, uTexel.y)).rgb);
        float edge = abs(right - left) + abs(below - above);
        if (edge >= uPeakingThreshold) {
            displayed = mix(displayed, vec3(0.12, 0.94, 0.42), clamp(edge * 3.0, 0.45, 1.0) * uOpacity);
        }
    }

    fragmentColor = vec4(displayed, source.a);
}
