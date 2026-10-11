#version 100

precision mediump float;
precision mediump sampler2D;
const highp int kMaxLoopLimit_S1_c0 = 8;
uniform highp vec4 uclamp_S1_c0_c0_c0;
uniform highp mat3 umatrix_S1_c0_c0;
uniform mediump vec4 uoffsetsAndKernel_S1_c0[14];
uniform mediump vec2 udir_S1_c0;
uniform highp mat3 umatrix_S1;
uniform sampler2D uTextureSampler_0_S1;
varying highp vec2 vTransformedCoords_2_S0;
void main() {
highp vec2 _26_tmp_1_coords = vTransformedCoords_2_S0;
mediump vec4 _27_sum = vec4(0.0);
for (highp int _28_i = 0;_28_i < kMaxLoopLimit_S1_c0; ++_28_i) {
mediump vec4 _29_s = uoffsetsAndKernel_S1_c0[_28_i];
highp vec2 _30_inCoord = (umatrix_S1_c0_c0 * vec3(_26_tmp_1_coords + _29_s.x * udir_S1_c0, 1.0)).xy;
highp vec2 _31_subsetCoord;
_31_subsetCoord.x = _30_inCoord.x;
_31_subsetCoord.y = _30_inCoord.y;
highp vec2 _32_clampedCoord;
_32_clampedCoord.x = _31_subsetCoord.x;
_32_clampedCoord.y = clamp(_31_subsetCoord.y, uclamp_S1_c0_c0_c0.y, uclamp_S1_c0_c0_c0.w);
mediump vec4 _33_textureColor = texture2D(uTextureSampler_0_S1, _32_clampedCoord, -0.475);
_27_sum += _29_s.y * _33_textureColor;
highp vec2 _34_inCoord = (umatrix_S1_c0_c0 * vec3(_26_tmp_1_coords + _29_s.z * udir_S1_c0, 1.0)).xy;
highp vec2 _35_subsetCoord;
_35_subsetCoord.x = _34_inCoord.x;
_35_subsetCoord.y = _34_inCoord.y;
highp vec2 _36_clampedCoord;
_36_clampedCoord.x = _35_subsetCoord.x;
_36_clampedCoord.y = clamp(_35_subsetCoord.y, uclamp_S1_c0_c0_c0.y, uclamp_S1_c0_c0_c0.w);
mediump vec4 _37_textureColor = texture2D(uTextureSampler_0_S1, _36_clampedCoord, -0.475);
_27_sum += _29_s.w * _37_textureColor;
}
mediump vec4 output_S1 = _27_sum;
{
gl_FragColor = output_S1;
}
}
