#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
uniform highp mat3 umatrix_S1_c0_c0;
uniform mediump float ucornerRadius_S1_c0;
uniform highp vec4 uproxyRect_S1_c0;
uniform mediump float ublurRadius_S1_c0;
uniform sampler2D uTextureSampler_0_S1;
varying mediump vec4 vcolor_S0;
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vcolor_S0;
highp vec2 _9_translatedFragPosFloat = sk_FragCoord.xy - uproxyRect_S1_c0.xy;
highp vec2 _10_proxyCenter = (uproxyRect_S1_c0.zw - uproxyRect_S1_c0.xy) * 0.5;
mediump float _11_edgeSize = (2.0 * ublurRadius_S1_c0 + ucornerRadius_S1_c0) + 0.5;
_9_translatedFragPosFloat -= _10_proxyCenter;
mediump vec2 _12_fragDirection = sign(_9_translatedFragPosFloat);
_9_translatedFragPosFloat = abs(_9_translatedFragPosFloat);
mediump vec2 _13_translatedFragPosHalf = _9_translatedFragPosFloat - (_10_proxyCenter - _11_edgeSize);
_13_translatedFragPosHalf = max(_13_translatedFragPosHalf, 0.0);
_13_translatedFragPosHalf *= _12_fragDirection;
_13_translatedFragPosHalf += vec2(_11_edgeSize);
mediump vec2 _14_proxyDims = vec2(2.0 * _11_edgeSize);
mediump vec2 _15_texCoord = _13_translatedFragPosHalf / _14_proxyDims;
mediump vec4 output_S1 = texture2D(uTextureSampler_0_S1, (umatrix_S1_c0_c0 * vec3(_15_texCoord, 1.0)).xy, -0.475).wwww;
{
gl_FragColor = outputColor_S0 * output_S1;
}
}
