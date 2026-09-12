#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp mat3 umatrix_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_2_S0;
void main() {
mediump vec4 outputColor_S0 = vcolor_S0;
mediump vec4 output_S1 = texture2D(uTextureSampler_0_S1, vTransformedCoords_2_S0, -0.475).wwww;
{
gl_FragColor = outputColor_S0 * output_S1;
}
}
