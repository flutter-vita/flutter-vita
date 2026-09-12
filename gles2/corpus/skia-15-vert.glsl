#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
attribute highp vec2 inPosition;
attribute mediump vec4 inColor;
attribute mediump float inCoverage;
varying mediump vec4 vcolor_S0;
void main() {
mediump vec4 color = inColor;
color = color * inCoverage;
vcolor_S0 = color;
highp vec2 _tmp_1_inPosition = inPosition;
gl_Position = vec4(_tmp_1_inPosition, 0.0, 1.0);
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
