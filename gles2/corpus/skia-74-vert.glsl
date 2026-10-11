#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
uniform highp mat3 umatrix_S1_c0_c0_c1;
attribute highp vec2 position;
attribute highp float coverage;
attribute mediump vec4 color;
attribute highp vec2 localCoord;
varying mediump vec4 vcolor_S0;
varying highp float vcoverage_S0;
varying highp vec2 vTransformedCoords_7_S0;
void main() {
highp vec2 position = position;
vcolor_S0 = color;
vcoverage_S0 = coverage;
gl_Position = vec4(position, 0.0, 1.0);
{
vTransformedCoords_7_S0 = (umatrix_S1_c0_c0_c1 * vec3(localCoord, 1.0)).xy;
}
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
