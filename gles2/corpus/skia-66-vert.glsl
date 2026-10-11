#version 100

precision mediump float;
precision mediump sampler2D;
struct Varyings_S0 {
mediump vec4 color;
highp vec2 position;
};
struct Attributes_S0 {
highp vec2 pos;
mediump vec4 color;
};
uniform highp vec4 sk_RTAdjust;
attribute highp vec2 pos;
attribute mediump vec4 color;
varying mediump vec4 vcolor_S0;
Varyings_S0 custom_mesh_vs_S0_SS(const Attributes_S0 a) {
Varyings_S0 v;
v.color = a.color;
v.position = a.pos;
return v;
}
void main() {
Attributes_S0 attributes;
attributes.pos = pos;
attributes.color = color;
Varyings_S0 varyings = custom_mesh_vs_S0_SS(attributes);
vcolor_S0 = varyings.color;
highp vec2 pos = varyings.position;
highp vec2 _tmp_1_pos = pos;
gl_Position = vec4(_tmp_1_pos, 0.0, 1.0);
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
