#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
uniform highp float uSrcTF_S0[7];
uniform highp mat3 uColorXform_S0;
uniform highp float uDstTF_S0[7];
uniform highp vec4 uinnerRect_S1;
uniform mediump vec2 uradiusPlusHalf_S1;
uniform sampler2D uTextureSampler_0_S0;
varying highp vec2 vlocalCoord_S0;
highp float src_tf_S0_ff(highp float x) {
highp float G = uSrcTF_S0[0];
highp float A = uSrcTF_S0[1];
highp float B = uSrcTF_S0[2];
highp float C = uSrcTF_S0[3];
highp float D = uSrcTF_S0[4];
highp float E = uSrcTF_S0[5];
highp float F = uSrcTF_S0[6];
highp float s = sign(x);
highp float y = abs(x);
highp float z = y < D ? C * y + F : pow(A * y + B, G) + E;
return s * z;
}
highp float dst_tf_S0_ff(highp float x) {
highp float G = uDstTF_S0[0];
highp float A = uDstTF_S0[1];
highp float B = uDstTF_S0[2];
highp float C = uDstTF_S0[3];
highp float D = uDstTF_S0[4];
highp float E = uDstTF_S0[5];
highp float F = uDstTF_S0[6];
highp float s = sign(x);
highp float y = abs(x);
highp float z = y < D ? C * y + F : pow(A * y + B, G) + E;
return s * z;
}
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vec4(1.0);
highp vec2 texCoord = vlocalCoord_S0;
highp vec4 _1_color = texture2D(uTextureSampler_0_S0, texCoord, -0.475);
_1_color.x = src_tf_S0_ff(_1_color.x);
_1_color.y = src_tf_S0_ff(_1_color.y);
_1_color.z = src_tf_S0_ff(_1_color.z);
highp vec4 _2_color = _1_color;
_2_color.xyz = uColorXform_S0 * _2_color.xyz;
_1_color = _2_color;
_1_color.x = dst_tf_S0_ff(_1_color.x);
_1_color.y = dst_tf_S0_ff(_1_color.y);
_1_color.z = dst_tf_S0_ff(_1_color.z);
outputColor_S0 = _1_color;
highp vec2 _3_dxy0 = uinnerRect_S1.xy - sk_FragCoord.xy;
highp vec2 _4_dxy1 = sk_FragCoord.xy - uinnerRect_S1.zw;
highp vec2 _5_dxy = max(max(_3_dxy0, _4_dxy1), 0.0);
mediump float _6_alpha = clamp(uradiusPlusHalf_S1.x - length(_5_dxy), 0.0, 1.0);
mediump vec4 output_S1 = vec4(_6_alpha);
{
gl_FragColor = outputColor_S0 * output_S1;
}
}
