#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
attribute highp vec2 position;
attribute highp float coverage;
attribute highp vec2 localCoord;
varying highp vec2 vlocalCoord_S0;
varying highp float vcoverage_S0;
void main() {
highp vec2 position = position;
vlocalCoord_S0 = localCoord;
vcoverage_S0 = coverage;
gl_Position = vec4(position, 0.0, 1.0);
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
