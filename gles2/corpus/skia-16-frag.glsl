#version 100

precision mediump float;
precision mediump sampler2D;
uniform sampler2D uTextureSampler_0_S0;
varying mediump vec4 vcolor_S0;
varying highp vec2 vlocalCoord_S0;
void main() {
mediump vec4 outputColor_S0 = vcolor_S0;
highp vec2 texCoord = vlocalCoord_S0;
outputColor_S0 = texture2D(uTextureSampler_0_S0, texCoord, -0.475) * outputColor_S0;
{
gl_FragColor = outputColor_S0;
}
}
