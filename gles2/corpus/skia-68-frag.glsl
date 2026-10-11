#version 100

uniform highp vec2 u_skRTFlip;
precision mediump float;
precision mediump sampler2D;
varying mediump vec4 vcolor_S0;
varying highp float vcoverage_S0;
varying highp vec4 vgeomSubset_S0;
void main() {
highp     vec4 sk_FragCoord = vec4(gl_FragCoord.x, u_skRTFlip.x + u_skRTFlip.y * gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
mediump vec4 outputColor_S0 = vcolor_S0;
highp float coverage = vcoverage_S0;
highp vec4 geoSubset = vgeomSubset_S0;
highp vec4 dists4 = clamp(vec4(1.0, 1.0, -1.0, -1.0) * (sk_FragCoord.xyxy - geoSubset), 0.0, 1.0);
highp vec2 dists2 = (dists4.xy + dists4.zw) - 1.0;
coverage = min(coverage, dists2.x * dists2.y);
mediump vec4 outputCoverage_S0 = vec4(coverage);
{
gl_FragColor = outputColor_S0 * outputCoverage_S0;
}
}
