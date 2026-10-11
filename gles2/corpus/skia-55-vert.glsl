#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
uniform highp mat3 umatrix_S1_c0;
attribute highp vec2 position;
attribute highp vec2 localCoord;
varying highp vec2 vTransformedCoords_3_S0;
void main() {
gl_Position = vec4(position, 0.0, 1.0);
{
vTransformedCoords_3_S0 = (umatrix_S1_c0 * vec3(localCoord, 1.0)).xy;
}
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
