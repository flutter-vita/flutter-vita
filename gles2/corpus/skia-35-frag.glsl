#version 100

precision mediump float;
precision mediump sampler2D;
const highp int kMaxLoopLimit_S1_c0 = 4;
uniform highp vec4 usubset_S1_c0_c0_c0;
uniform highp vec4 uclamp_S1_c0_c0_c0;
uniform highp mat3 umatrix_S1_c0_c0;
uniform mediump vec4 uoffsetsAndKernel_S1_c0[14];
uniform mediump vec2 udir_S1_c0;
uniform highp mat3 umatrix_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_2_S0;
void main() {
highp vec2 _56_tmp_1_coords = vTransformedCoords_2_S0;
mediump vec4 _57_sum = vec4(0.0);
for (highp int _58_i = 0;_58_i < kMaxLoopLimit_S1_c0; ++_58_i) {
mediump vec4 _59_s = uoffsetsAndKernel_S1_c0[_58_i];
highp vec2 _60_inCoord = (umatrix_S1_c0_c0 * vec3(_56_tmp_1_coords + _59_s.x * udir_S1_c0, 1.0)).xy;
highp vec2 _61_subsetCoord;
{
highp float _62_w = usubset_S1_c0_c0_c0.z - usubset_S1_c0_c0_c0.x;
highp float _63_w2 = 2.0 * _62_w;
highp float _64_m = mod(_60_inCoord.x - usubset_S1_c0_c0_c0.x, _63_w2);
_61_subsetCoord.x = mix(_64_m, _63_w2 - _64_m, step(_62_w, _64_m)) + usubset_S1_c0_c0_c0.x;
}
{
highp float _65_w = usubset_S1_c0_c0_c0.w - usubset_S1_c0_c0_c0.y;
highp float _66_w2 = 2.0 * _65_w;
highp float _67_m = mod(_60_inCoord.y - usubset_S1_c0_c0_c0.y, _66_w2);
_61_subsetCoord.y = mix(_67_m, _66_w2 - _67_m, step(_65_w, _67_m)) + usubset_S1_c0_c0_c0.y;
}
highp vec2 _68_clampedCoord = clamp(_61_subsetCoord, uclamp_S1_c0_c0_c0.xy, uclamp_S1_c0_c0_c0.zw);
mediump vec4 _69_textureColor = texture2D(uTextureSampler_0_S1, _68_clampedCoord, -0.475);
_57_sum += _59_s.y * _69_textureColor;
highp vec2 _70_inCoord = (umatrix_S1_c0_c0 * vec3(_56_tmp_1_coords + _59_s.z * udir_S1_c0, 1.0)).xy;
highp vec2 _71_subsetCoord;
{
highp float _72_w = usubset_S1_c0_c0_c0.z - usubset_S1_c0_c0_c0.x;
highp float _73_w2 = 2.0 * _72_w;
highp float _74_m = mod(_70_inCoord.x - usubset_S1_c0_c0_c0.x, _73_w2);
_71_subsetCoord.x = mix(_74_m, _73_w2 - _74_m, step(_72_w, _74_m)) + usubset_S1_c0_c0_c0.x;
}
{
highp float _75_w = usubset_S1_c0_c0_c0.w - usubset_S1_c0_c0_c0.y;
highp float _76_w2 = 2.0 * _75_w;
highp float _77_m = mod(_70_inCoord.y - usubset_S1_c0_c0_c0.y, _76_w2);
_71_subsetCoord.y = mix(_77_m, _76_w2 - _77_m, step(_75_w, _77_m)) + usubset_S1_c0_c0_c0.y;
}
highp vec2 _78_clampedCoord = clamp(_71_subsetCoord, uclamp_S1_c0_c0_c0.xy, uclamp_S1_c0_c0_c0.zw);
mediump vec4 _79_textureColor = texture2D(uTextureSampler_0_S1, _78_clampedCoord, -0.475);
_57_sum += _59_s.w * _79_textureColor;
}
mediump vec4 output_S1 = _57_sum;
{
gl_FragColor = output_S1;
}
}
