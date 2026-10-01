#version 100

precision mediump float;
precision mediump sampler2D;
const highp int kMaxLoopLimit_S1_c0 = 3;
uniform highp mat3 umatrix_S1_c0_c0;
uniform mediump vec4 ukernel_S1_c0[7];
uniform mediump vec4 uoffsets_S1_c0[14];
uniform highp mat3 umatrix_S1;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
varying highp vec2 vTransformedCoords_2_S0;
void main() {
highp vec2 _7_tmp_1_coords = vTransformedCoords_2_S0;
mediump vec4 _8_sum = vec4(0.0);
for (highp int _9_i = 0;_9_i < kMaxLoopLimit_S1_c0; ++_9_i) {
mediump vec4 _10_k = ukernel_S1_c0[_9_i];
mediump vec4 _11_o = uoffsets_S1_c0[2 * _9_i];
_8_sum += _10_k.x * texture2D(uTextureSampler_0_S1, (umatrix_S1_c0_c0 * vec3(_7_tmp_1_coords + _11_o.xy, 1.0)).xy, -0.475);
_8_sum += _10_k.y * texture2D(uTextureSampler_0_S1, (umatrix_S1_c0_c0 * vec3(_7_tmp_1_coords + _11_o.zw, 1.0)).xy, -0.475);
_11_o = uoffsets_S1_c0[2 * _9_i + 1];
_8_sum += _10_k.z * texture2D(uTextureSampler_0_S1, (umatrix_S1_c0_c0 * vec3(_7_tmp_1_coords + _11_o.xy, 1.0)).xy, -0.475);
_8_sum += _10_k.w * texture2D(uTextureSampler_0_S1, (umatrix_S1_c0_c0 * vec3(_7_tmp_1_coords + _11_o.zw, 1.0)).xy, -0.475);
}
mediump vec4 output_S1 = _8_sum;
{
gl_FragColor = output_S1;
}
}
