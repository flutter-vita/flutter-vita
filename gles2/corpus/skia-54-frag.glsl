#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp mat3 umatrix_S1_c0;
uniform sampler2D uTextureSampler_0_S1;
varying highp vec2 vTransformedCoords_3_S0;
void main() {
mediump vec4 outputColor_S0 = vec4(1.0);
mediump vec4 output_S1 = texture2D(uTextureSampler_0_S1, vTransformedCoords_3_S0, -0.475) * outputColor_S0;
{
gl_FragColor = output_S1;
}
}
