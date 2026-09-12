#version 100

precision mediump float;
precision mediump sampler2D;
uniform mediump vec4 ucolor_S1_c0;
uniform highp mat3 umatrix_S1_c1_c0;
uniform mediump vec4 ublend_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_5_S0;
void main() {
mediump vec4 outputColor_S0 = vcolor_S0;
mediump vec4 _5_input = outputColor_S0;
_5_input = texture2D(uTextureSampler_0_S1, vTransformedCoords_5_S0, -0.475);
mediump vec2 _7_d = ublend_S1.xy + ublend_S1.zw * vec2(_5_input.w, ucolor_S1_c0.w);
mediump vec4 output_S1 = ucolor_S1_c0 * _7_d.x + _5_input * _7_d.y;
{
gl_FragColor = output_S1;
}
}
