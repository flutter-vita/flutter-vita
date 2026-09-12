#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
uniform highp vec4 urectUniform_S1_c0;
uniform sampler2D uTextureSampler_0_S0;
varying highp vec2 vTextureCoords_S0;
varying highp float vTexIndex_S0;
varying mediump vec4 vinColor_S0;
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vinColor_S0;
mediump vec4 texColor = texture2D(uTextureSampler_0_S0, vTextureCoords_S0, -0.475).wwww;
mediump vec4 outputCoverage_S0 = texColor;
mediump float _5_coverage;
{
mediump vec4 _6_dists4 = clamp(vec4(1.0, 1.0, -1.0, -1.0) * (sk_FragCoord.xyxy - urectUniform_S1_c0), 0.0, 1.0);
mediump vec2 _7_dists2 = (_6_dists4.xy + _6_dists4.zw) - 1.0;
_5_coverage = _7_dists2.x * _7_dists2.y;
}
mediump vec4 output_S1 = vec4(_5_coverage) * outputCoverage_S0;
{
gl_FragColor = outputColor_S0 * output_S1;
}
}
