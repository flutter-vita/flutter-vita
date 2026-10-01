#version 100

precision mediump float;
precision mediump sampler2D;
uniform mediump vec4 ucolor_S1_c0;
uniform highp mat3 umatrix_S1_c1_c0_c0_c0;
uniform mediump mat4 ucoefficients_S1_c1_c0_c0;
uniform highp mat3 umatrix_S1_c1_c0;
uniform mediump vec4 ublend_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_5_S0;
mediump vec4 MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(mediump vec4 _input, highp vec2 _coords) {
return texture2D(uTextureSampler_0_S1, (umatrix_S1_c1_c0_c0_c0 * vec3(_coords, 1.0)).xy, -0.475);
}
void main() {
mediump vec4 outputColor_S0 = vcolor_S0;
mediump vec4 _35_input = outputColor_S0;
highp vec2 _36_coord = vTransformedCoords_5_S0 - vec2(0.5);
mediump vec2 _37_f = fract(_36_coord);
_36_coord += 0.5 - _37_f;
mediump vec4 _38_wx = ucoefficients_S1_c1_c0_c0 * vec4(1.0, _37_f.x, _37_f.x * _37_f.x, (_37_f.x * _37_f.x) * _37_f.x);
mediump vec4 _39_wy = ucoefficients_S1_c1_c0_c0 * vec4(1.0, _37_f.y, _37_f.y * _37_f.y, (_37_f.y * _37_f.y) * _37_f.y);
mediump vec4 _40_rowColors[4];
_40_rowColors[0] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(-1.0));
_40_rowColors[1] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(0.0, -1.0));
_40_rowColors[2] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(1.0, -1.0));
_40_rowColors[3] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(2.0, -1.0));
mediump vec4 _41_s0 = ((_38_wx.x * _40_rowColors[0] + _38_wx.y * _40_rowColors[1]) + _38_wx.z * _40_rowColors[2]) + _38_wx.w * _40_rowColors[3];
_40_rowColors[0] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(-1.0, 0.0));
_40_rowColors[1] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord);
_40_rowColors[2] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(1.0, 0.0));
_40_rowColors[3] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(2.0, 0.0));
mediump vec4 _42_s1 = ((_38_wx.x * _40_rowColors[0] + _38_wx.y * _40_rowColors[1]) + _38_wx.z * _40_rowColors[2]) + _38_wx.w * _40_rowColors[3];
_40_rowColors[0] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(-1.0, 1.0));
_40_rowColors[1] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(0.0, 1.0));
_40_rowColors[2] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(1.0));
_40_rowColors[3] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(2.0, 1.0));
mediump vec4 _43_s2 = ((_38_wx.x * _40_rowColors[0] + _38_wx.y * _40_rowColors[1]) + _38_wx.z * _40_rowColors[2]) + _38_wx.w * _40_rowColors[3];
_40_rowColors[0] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(-1.0, 2.0));
_40_rowColors[1] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(0.0, 2.0));
_40_rowColors[2] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(1.0, 2.0));
_40_rowColors[3] = MatrixEffect_S1_c1_c0_c0_c0_h4h4f2(_35_input, _36_coord + vec2(2.0));
mediump vec4 _44_s3 = ((_38_wx.x * _40_rowColors[0] + _38_wx.y * _40_rowColors[1]) + _38_wx.z * _40_rowColors[2]) + _38_wx.w * _40_rowColors[3];
mediump vec4 _45_bicubicColor = ((_39_wy.x * _41_s0 + _39_wy.y * _42_s1) + _39_wy.z * _43_s2) + _39_wy.w * _44_s3;
_45_bicubicColor.w = clamp(_45_bicubicColor.w, 0.0, 1.0);
_45_bicubicColor.xyz = max(vec3(0.0), min(_45_bicubicColor.xyz, _45_bicubicColor.www));
_35_input = _45_bicubicColor;
mediump vec2 _47_d = ublend_S1.xy + ublend_S1.zw * vec2(_35_input.w, ucolor_S1_c0.w);
mediump vec4 output_S1 = ucolor_S1_c0 * _47_d.x + _35_input * _47_d.y;
{
gl_FragColor = output_S1;
}
}

