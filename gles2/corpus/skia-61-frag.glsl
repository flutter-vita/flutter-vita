#version 100

precision mediump float;
precision mediump sampler2D;
uniform mediump vec4 uColor_S0;
uniform sampler2D uTextureSampler_0_S0;
varying highp vec2 vTextureCoords_S0;
varying highp float vTexIndex_S0;
void main() {
mediump vec4 outputColor_S0 = uColor_S0;
mediump vec4 texColor = texture2D(uTextureSampler_0_S0, vTextureCoords_S0, -0.475);
outputColor_S0 = outputColor_S0 * texColor;
{
gl_FragColor = outputColor_S0;
}
}
