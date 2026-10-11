#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
attribute highp vec2 position;
attribute highp float coverage;
attribute mediump vec4 color;
attribute highp vec4 geomSubset;
varying mediump vec4 vcolor_S0;
varying highp float vcoverage_S0;
varying highp vec4 vgeomSubset_S0;
void main() {
highp vec2 position = position;
vcolor_S0 = color;
vcoverage_S0 = coverage;
vgeomSubset_S0 = geomSubset;
gl_Position = vec4(position, 0.0, 1.0);
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
