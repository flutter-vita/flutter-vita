#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
attribute highp vec2 inPosition;
attribute mediump vec4 inColor;
attribute highp vec2 inEllipseOffset;
attribute highp vec4 inEllipseRadii;
varying highp vec2 vEllipseOffsets_S0;
varying highp vec4 vEllipseRadii_S0;
varying mediump vec4 vinColor_S0;
void main() {
vEllipseOffsets_S0 = inEllipseOffset;
vEllipseRadii_S0 = inEllipseRadii;
vinColor_S0 = inColor;
highp vec2 _tmp_0_inPosition = inPosition;
gl_Position = vec4(_tmp_0_inPosition, 0.0, 1.0);
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
