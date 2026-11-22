#version 440

// Shelly's backdrop blur (src/ui/wallpaper/gl_renderer.cpp, kBlurFragment), which is
// ported from Noctalia v5.5.0. Copyright (c) 2026 noctalia-dev, MIT licence.
// Separable Gaussian with a fixed 81-tap loop; radius sets how many taps count.
//
// Rebuild after a change:  /usr/lib/qt6/bin/qsb --qt6 -o blur.frag.qsb blur.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float radius;
    vec2 texelSize;
    vec2 direction;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 color = vec4(0.0);
    float total = 0.0;
    float sigma = max(radius / 2.0, 0.0001);
    for (int i = -40; i <= 40; i++) {
        float fi = float(i);
        if (abs(fi) > radius) continue;
        float w = exp(-fi * fi / (2.0 * sigma * sigma));
        color += texture(source, qt_TexCoord0 + direction * texelSize * fi) * w;
        total += w;
    }
    fragColor = color / total * qt_Opacity;
}
