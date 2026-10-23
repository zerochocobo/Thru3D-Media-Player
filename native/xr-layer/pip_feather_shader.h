#pragma once
// Static coverage only: no decoded video texture, RGB processing or readback.
inline constexpr const char* pip_feather_vertex = R"GLSL(#version 300 es
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)GLSL";
inline constexpr const char* pip_feather_fragment = R"GLSL(#version 300 es
precision highp float;
uniform vec2 feather;
uniform vec2 tile_size;
uniform float first_row;
out highp vec4 result;
void main() {
    vec2 uv = (gl_FragCoord.xy - vec2(2.0, first_row + 2.0)) / tile_size;
    vec2 fade = smoothstep(vec2(0.0), feather, min(uv, vec2(1.0) - uv));
    result = vec4(0.0, 0.0, 0.0, fade.x * fade.y);
}
)GLSL";
