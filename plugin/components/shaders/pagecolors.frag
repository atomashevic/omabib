#version 440
// Recolors a rendered PDF page into the theme: page white becomes the theme
// background and black ink its text color, with every lightness in between on
// that ramp. Colored ink keeps its hue and saturation, so figures, links and
// highlights stay recognizable (like Zathura's recolor-keephue).
//
// Rebuild with scripts/build-shaders after editing.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 background;
    vec4 foreground;
    float keepHue;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    // Pages render opaque; an unloaded texture is transparent and reads as paper.
    vec3 rgb = c.a > 0.0 ? c.rgb / c.a : vec3(1.0);
    float lightness = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 ramp = mix(foreground.rgb, background.rgb, lightness);
    vec3 chroma = (rgb - vec3(lightness)) * keepHue;
    fragColor = vec4(clamp(ramp + chroma, 0.0, 1.0), 1.0) * qt_Opacity;
}
