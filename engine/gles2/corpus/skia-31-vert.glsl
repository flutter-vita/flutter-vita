#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
attribute highp vec2 position;
attribute highp vec2 localCoord;
attribute highp vec4 texSubset;
varying highp vec2 vlocalCoord_S0;
varying highp vec4 vtexSubset_S0;
void main() {
vlocalCoord_S0 = localCoord;
vtexSubset_S0 = texSubset;
gl_Position = vec4(position, 0.0, 1.0);
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
