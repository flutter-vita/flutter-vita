#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
uniform highp vec4 uinnerRect_S1;
uniform mediump vec2 uradiusPlusHalf_S1;
varying highp vec2 vEllipseOffsets_S0;
varying highp vec4 vEllipseRadii_S0;
varying mediump vec4 vinColor_S0;
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vinColor_S0;
highp vec2 offset = vEllipseOffsets_S0;
highp float test = dot(offset, offset) - 1.0;
highp vec2 grad = (2.0 * offset) * vEllipseRadii_S0.xy;
highp float grad_dot = dot(grad, grad);
grad_dot = max(grad_dot, 1.1755e-38);
highp float invlen = (1.0 / sqrt(grad_dot));
highp float edgeAlpha = clamp(0.5 - test * invlen, 0.0, 1.0);
mediump vec4 outputCoverage_S0 = vec4(edgeAlpha);
highp vec2 _0_dxy0 = uinnerRect_S1.xy - sk_FragCoord.xy;
highp vec2 _1_dxy1 = sk_FragCoord.xy - uinnerRect_S1.zw;
highp vec2 _2_dxy = max(max(_0_dxy0, _1_dxy1), 0.0);
mediump float _3_alpha = clamp(uradiusPlusHalf_S1.x - length(_2_dxy), 0.0, 1.0);
mediump vec4 output_S1 = outputCoverage_S0 * _3_alpha;
{
gl_FragColor = outputColor_S0 * output_S1;
}
}
