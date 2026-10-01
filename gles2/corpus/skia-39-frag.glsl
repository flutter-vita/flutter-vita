#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
uniform highp vec4 uscale_S1_c0_c0_c0_c0[2];
uniform highp vec4 ubias_S1_c0_c0_c0_c0[2];
uniform mediump float uthreshold_S1_c0_c0_c0_c0;
uniform highp mat3 umatrix_S1_c0_c0_c1;
uniform mediump vec4 uleftBorderColor_S1_c0_c0;
uniform mediump vec4 urightBorderColor_S1_c0_c0;
uniform highp mat3 umatrix_S1_c1;
uniform mediump float urange_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_7_S0;
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vcolor_S0;
mediump vec4 _40_tmp_6_inColor = outputColor_S0;
mediump vec4 _41_input = _40_tmp_6_inColor;
highp vec2 _44_tmp_3_coords = vTransformedCoords_7_S0;
mediump vec4 _45_t = vec4(_44_tmp_3_coords.x + 1e-05, 1.0, 0.0, 0.0);
mediump vec4 _46_outColor;
if (_45_t.x < 0.0) {
_46_outColor = uleftBorderColor_S1_c0_c0;
} else if (_45_t.x > 1.0) {
_46_outColor = urightBorderColor_S1_c0_c0;
} else {
highp vec2 _48_tmp_1_coords = vec2(_45_t.x, 0.0);
mediump float _49_t = _48_tmp_1_coords.x;
highp vec4 _50_s;
highp vec4 _51_b;
if (_49_t < uthreshold_S1_c0_c0_c0_c0) {
_50_s = uscale_S1_c0_c0_c0_c0[0];
_51_b = ubias_S1_c0_c0_c0_c0[0];
} else {
_50_s = uscale_S1_c0_c0_c0_c0[1];
_51_b = ubias_S1_c0_c0_c0_c0[1];
}
highp vec4 _52_color = _49_t * _50_s + _51_b;
_52_color.xyz *= _52_color.w;
_46_outColor = _52_color;
}
_41_input = _46_outColor;
mediump vec4 _54_color = _41_input;
mediump float _55_value = texture2D(uTextureSampler_0_S1, (umatrix_S1_c1 * vec3(sk_FragCoord.xy, 1.0)).xy, -0.475).w - 0.5;
mediump vec4 output_S1 = vec4(clamp(_54_color.xyz + _55_value * urange_S1, 0.0, _54_color.w), _54_color.w);
{
gl_FragColor = output_S1;
}
}
