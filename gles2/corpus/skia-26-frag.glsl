#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp mat3 umatrix_S1_c0;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_3_S0;
void main() {
mediump vec4 outputColor_S0 = vcolor_S0;
mediump vec4 _0_input = outputColor_S0;
_0_input = texture2D(uTextureSampler_0_S1, vTransformedCoords_3_S0, -0.475);
mediump vec4 output_S1 = _0_input;
{
gl_FragColor = output_S1;
}
}
