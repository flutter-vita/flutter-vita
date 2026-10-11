#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
uniform highp mat3 umatrix_S1_c0_c0_c1;
attribute highp vec2 inPosition;
attribute mediump vec4 inColor;
attribute highp vec2 inLocalCoord;
attribute mediump float inCoverage;
varying mediump vec4 vcolor_S0;
varying mediump float vinCoverage_S0;
varying highp vec2 vTransformedCoords_7_S0;
void main() {
mediump vec4 color = inColor;
vcolor_S0 = color;
highp vec2 _tmp_1_inPosition = inPosition;
vinCoverage_S0 = inCoverage;
gl_Position = vec4(_tmp_1_inPosition, 0.0, 1.0);
{
vTransformedCoords_7_S0 = (umatrix_S1_c0_c0_c1 * vec3(inLocalCoord, 1.0)).xy;
}
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
