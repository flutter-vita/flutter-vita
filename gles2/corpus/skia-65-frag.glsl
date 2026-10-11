#version 100

precision mediump float;
precision mediump sampler2D;
struct Varyings_S0 {
mediump vec4 color;
highp vec2 position;
};
uniform mediump vec4 ucolor_S1_c0;
varying mediump vec4 vcolor_S0;
highp vec2 custom_mesh_fs_S0_f2Sf4(const Varyings_S0 v, out highp vec4 color) {
color = vec4(v.color.zyx * v.color.w, v.color.w);
return v.position;
}
void main() {
mediump vec4 outputColor_S0;
Varyings_S0 varyings;
varyings.color = vcolor_S0;
highp vec4 color;
custom_mesh_fs_S0_f2Sf4(varyings, color);
outputColor_S0 = color;
mediump float _5_factor = 1.0 - outputColor_S0.w;
_5_factor = exp((-_5_factor * _5_factor) * 4.0) - 0.018;
mediump vec4 output_S1 = ucolor_S1_c0 * vec4(_5_factor);
{
gl_FragColor = output_S1;
}
}
