#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
uniform mediump vec4 ustart_S1_c0_c0_c0_c0;
uniform mediump vec4 uend_S1_c0_c0_c0_c0;
uniform highp mat3 umatrix_S1_c0_c0_c1;
uniform mediump vec4 uleftBorderColor_S1_c0_c0;
uniform mediump vec4 urightBorderColor_S1_c0_c0;
uniform highp mat3 umatrix_S1_c1;
uniform mediump float urange_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp float vcoverage_S0;
varying highp vec2 vTransformedCoords_7_S0;
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vcolor_S0;
highp float coverage = vcoverage_S0;
mediump vec4 outputCoverage_S0 = vec4(coverage);
mediump vec4 _28_tmp_6_inColor = outputColor_S0;
mediump vec4 _29_input = _28_tmp_6_inColor;
highp vec2 _32_tmp_3_coords = vTransformedCoords_7_S0;
mediump vec4 _33_t = vec4(_32_tmp_3_coords.x + 1e-05, 1.0, 0.0, 0.0);
mediump vec4 _34_outColor;
if (_33_t.x < 0.0) {
_34_outColor = uleftBorderColor_S1_c0_c0;
} else if (_33_t.x > 1.0) {
_34_outColor = urightBorderColor_S1_c0_c0;
} else {
highp vec2 _36_tmp_1_coords = vec2(_33_t.x, 0.0);
highp vec4 _37_color = mix(ustart_S1_c0_c0_c0_c0, uend_S1_c0_c0_c0_c0, _36_tmp_1_coords.x);
_37_color.xyz *= _37_color.w;
_34_outColor = _37_color;
}
_29_input = _34_outColor;
mediump vec4 _39_color = _29_input;
mediump float _40_value = texture2D(uTextureSampler_0_S1, (umatrix_S1_c1 * vec3(sk_FragCoord.xy, 1.0)).xy, -0.475).w - 0.5;
mediump vec4 output_S1 = vec4(clamp(_39_color.xyz + _40_value * urange_S1, 0.0, _39_color.w), _39_color.w);
{
gl_FragColor = output_S1 * outputCoverage_S0;
}
}
