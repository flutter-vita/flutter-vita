#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
uniform highp vec4 uinnerRect_S1;
uniform mediump vec2 uradiusPlusHalf_S1;
uniform sampler2D uTextureSampler_0_S0;
varying highp vec2 vlocalCoord_S0;
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vec4(1.0);
highp vec2 texCoord = vlocalCoord_S0;
highp vec4 _1_color = texture2D(uTextureSampler_0_S0, texCoord, -0.475);
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
