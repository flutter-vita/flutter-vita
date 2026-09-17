#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp vec4 sk_RTAdjust;
uniform highp vec2 uAtlasSizeInv_S0;
attribute highp vec2 inPosition;
attribute mediump vec4 inColor;
attribute highp vec2 inTextureCoords;
varying highp vec2 vTextureCoords_S0;
varying highp float vTexIndex_S0;
varying mediump vec4 vinColor_S0;
void main() {
highp float texIdx = 0.0;
highp vec2 unormTexCoords = vec2(inTextureCoords.x, inTextureCoords.y);
vTextureCoords_S0 = unormTexCoords * uAtlasSizeInv_S0;
vTexIndex_S0 = texIdx;
vinColor_S0 = inColor;
gl_Position = vec4(inPosition, 0.0, 1.0);
gl_Position = vec4(gl_Position.xy * sk_RTAdjust.xz + gl_Position.ww * sk_RTAdjust.yw, 0.0, gl_Position.w);
}
