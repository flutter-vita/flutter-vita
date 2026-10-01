#version 100

precision mediump float;
precision mediump sampler2D;
const highp int kMaxLoopLimit_S1_c0 = 3;
uniform highp vec4 usubset_S1_c0_c0_c0;
uniform highp vec4 uclamp_S1_c0_c0_c0;
uniform highp mat3 umatrix_S1_c0_c0;
uniform mediump vec4 ukernel_S1_c0[7];
uniform mediump vec4 uoffsets_S1_c0[14];
uniform highp mat3 umatrix_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_2_S0;
void main() {
highp vec2 _97_tmp_1_coords = vTransformedCoords_2_S0;
mediump vec4 _98_sum = vec4(0.0);
for (highp int _99_i = 0;_99_i < kMaxLoopLimit_S1_c0; ++_99_i) {
mediump vec4 _100_k = ukernel_S1_c0[_99_i];
mediump vec4 _101_o = uoffsets_S1_c0[2 * _99_i];
highp vec2 _102_inCoord = (umatrix_S1_c0_c0 * vec3(_97_tmp_1_coords + _101_o.xy, 1.0)).xy;
highp vec2 _103_subsetCoord;
{
highp float _104_w = usubset_S1_c0_c0_c0.z - usubset_S1_c0_c0_c0.x;
highp float _105_w2 = 2.0 * _104_w;
highp float _106_m = mod(_102_inCoord.x - usubset_S1_c0_c0_c0.x, _105_w2);
_103_subsetCoord.x = mix(_106_m, _105_w2 - _106_m, step(_104_w, _106_m)) + usubset_S1_c0_c0_c0.x;
}
{
highp float _107_w = usubset_S1_c0_c0_c0.w - usubset_S1_c0_c0_c0.y;
highp float _108_w2 = 2.0 * _107_w;
highp float _109_m = mod(_102_inCoord.y - usubset_S1_c0_c0_c0.y, _108_w2);
_103_subsetCoord.y = mix(_109_m, _108_w2 - _109_m, step(_107_w, _109_m)) + usubset_S1_c0_c0_c0.y;
}
highp vec2 _110_clampedCoord = clamp(_103_subsetCoord, uclamp_S1_c0_c0_c0.xy, uclamp_S1_c0_c0_c0.zw);
mediump vec4 _111_textureColor = texture2D(uTextureSampler_0_S1, _110_clampedCoord, -0.475);
_98_sum += _100_k.x * _111_textureColor;
highp vec2 _112_inCoord = (umatrix_S1_c0_c0 * vec3(_97_tmp_1_coords + _101_o.zw, 1.0)).xy;
highp vec2 _113_subsetCoord;
{
highp float _114_w = usubset_S1_c0_c0_c0.z - usubset_S1_c0_c0_c0.x;
highp float _115_w2 = 2.0 * _114_w;
highp float _116_m = mod(_112_inCoord.x - usubset_S1_c0_c0_c0.x, _115_w2);
_113_subsetCoord.x = mix(_116_m, _115_w2 - _116_m, step(_114_w, _116_m)) + usubset_S1_c0_c0_c0.x;
}
{
highp float _117_w = usubset_S1_c0_c0_c0.w - usubset_S1_c0_c0_c0.y;
highp float _118_w2 = 2.0 * _117_w;
highp float _119_m = mod(_112_inCoord.y - usubset_S1_c0_c0_c0.y, _118_w2);
_113_subsetCoord.y = mix(_119_m, _118_w2 - _119_m, step(_117_w, _119_m)) + usubset_S1_c0_c0_c0.y;
}
highp vec2 _120_clampedCoord = clamp(_113_subsetCoord, uclamp_S1_c0_c0_c0.xy, uclamp_S1_c0_c0_c0.zw);
mediump vec4 _121_textureColor = texture2D(uTextureSampler_0_S1, _120_clampedCoord, -0.475);
_98_sum += _100_k.y * _121_textureColor;
_101_o = uoffsets_S1_c0[2 * _99_i + 1];
highp vec2 _122_inCoord = (umatrix_S1_c0_c0 * vec3(_97_tmp_1_coords + _101_o.xy, 1.0)).xy;
highp vec2 _123_subsetCoord;
{
highp float _124_w = usubset_S1_c0_c0_c0.z - usubset_S1_c0_c0_c0.x;
highp float _125_w2 = 2.0 * _124_w;
highp float _126_m = mod(_122_inCoord.x - usubset_S1_c0_c0_c0.x, _125_w2);
_123_subsetCoord.x = mix(_126_m, _125_w2 - _126_m, step(_124_w, _126_m)) + usubset_S1_c0_c0_c0.x;
}
{
highp float _127_w = usubset_S1_c0_c0_c0.w - usubset_S1_c0_c0_c0.y;
highp float _128_w2 = 2.0 * _127_w;
highp float _129_m = mod(_122_inCoord.y - usubset_S1_c0_c0_c0.y, _128_w2);
_123_subsetCoord.y = mix(_129_m, _128_w2 - _129_m, step(_127_w, _129_m)) + usubset_S1_c0_c0_c0.y;
}
highp vec2 _130_clampedCoord = clamp(_123_subsetCoord, uclamp_S1_c0_c0_c0.xy, uclamp_S1_c0_c0_c0.zw);
mediump vec4 _131_textureColor = texture2D(uTextureSampler_0_S1, _130_clampedCoord, -0.475);
_98_sum += _100_k.z * _131_textureColor;
highp vec2 _132_inCoord = (umatrix_S1_c0_c0 * vec3(_97_tmp_1_coords + _101_o.zw, 1.0)).xy;
highp vec2 _133_subsetCoord;
{
highp float _134_w = usubset_S1_c0_c0_c0.z - usubset_S1_c0_c0_c0.x;
highp float _135_w2 = 2.0 * _134_w;
highp float _136_m = mod(_132_inCoord.x - usubset_S1_c0_c0_c0.x, _135_w2);
_133_subsetCoord.x = mix(_136_m, _135_w2 - _136_m, step(_134_w, _136_m)) + usubset_S1_c0_c0_c0.x;
}
{
highp float _137_w = usubset_S1_c0_c0_c0.w - usubset_S1_c0_c0_c0.y;
highp float _138_w2 = 2.0 * _137_w;
highp float _139_m = mod(_132_inCoord.y - usubset_S1_c0_c0_c0.y, _138_w2);
_133_subsetCoord.y = mix(_139_m, _138_w2 - _139_m, step(_137_w, _139_m)) + usubset_S1_c0_c0_c0.y;
}
highp vec2 _140_clampedCoord = clamp(_133_subsetCoord, uclamp_S1_c0_c0_c0.xy, uclamp_S1_c0_c0_c0.zw);
mediump vec4 _141_textureColor = texture2D(uTextureSampler_0_S1, _140_clampedCoord, -0.475);
_98_sum += _100_k.w * _141_textureColor;
}
mediump vec4 output_S1 = _98_sum;
{
gl_FragColor = output_S1;
}
}
