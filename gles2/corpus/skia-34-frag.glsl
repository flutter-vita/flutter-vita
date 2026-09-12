#version 100

precision mediump float;
precision mediump sampler2D;
const highp int kMaxLoopLimit_S1_c0 = 4;
uniform highp mat3 umatrix_S1_c0_c0;
uniform mediump vec4 uoffsetsAndKernel_S1_c0[14];
uniform mediump vec2 udir_S1_c0;
uniform highp mat3 umatrix_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_2_S0;
void main() {
highp vec2 _6_tmp_1_coords = vTransformedCoords_2_S0;
mediump vec4 _7_sum = vec4(0.0);
for (highp int _8_i = 0;_8_i < kMaxLoopLimit_S1_c0; ++_8_i) {
mediump vec4 _9_s = uoffsetsAndKernel_S1_c0[_8_i];
_7_sum += _9_s.y * texture2D(uTextureSampler_0_S1, (umatrix_S1_c0_c0 * vec3(_6_tmp_1_coords + _9_s.x * udir_S1_c0, 1.0)).xy, -0.475);
_7_sum += _9_s.w * texture2D(uTextureSampler_0_S1, (umatrix_S1_c0_c0 * vec3(_6_tmp_1_coords + _9_s.z * udir_S1_c0, 1.0)).xy, -0.475);
}
mediump vec4 output_S1 = _7_sum;
{
gl_FragColor = output_S1;
}
}
