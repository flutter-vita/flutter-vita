#version 100

precision mediump float;
precision mediump sampler2D;
varying highp vec4 vinCircleEdge_S0;
varying mediump vec4 vinColor_S0;
void main() {
highp vec4 circleEdge = vinCircleEdge_S0;
mediump vec4 outputColor_S0 = vinColor_S0;
highp float d = length(circleEdge.xy);
mediump float distanceToOuterEdge = circleEdge.z * (1.0 - d);
mediump float edgeAlpha = clamp(distanceToOuterEdge, 0.0, 1.0);
mediump vec4 outputCoverage_S0 = vec4(edgeAlpha);
{
gl_FragColor = outputColor_S0 * outputCoverage_S0;
}
}
