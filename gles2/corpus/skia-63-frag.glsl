#version 100

precision mediump float;
precision mediump sampler2D;
uniform highp mat3 umatrix_S1_c0_c0;
uniform mediump mat4 um_S1;
uniform mediump vec4 uv_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_4_S0;
void main() {
mediump vec4 outputColor_S0 = vcolor_S0;
mediump vec4 _2_input = outputColor_S0;
mediump vec4 _3_input = _2_input;
_3_input = texture2D(uTextureSampler_0_S1, vTransformedCoords_4_S0, -0.475);
_2_input = _3_input;
{
_2_input = vec4(_2_input.xyz / max(_2_input.w, 0.0001), _2_input.w);
}
_2_input = um_S1 * _2_input + uv_S1;
{
_2_input = clamp(_2_input, 0.0, 1.0);
}
{
_2_input.xyz *= _2_input.w;
}
mediump vec4 output_S1 = _2_input;
{
gl_FragColor = output_S1;
}
}
