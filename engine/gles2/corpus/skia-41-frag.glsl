#version 100

precision mediump float;
precision mediump sampler2D;
varying highp vec2 vEllipseOffsets_S0;
varying highp vec4 vEllipseRadii_S0;
varying mediump vec4 vinColor_S0;
void main() {
mediump vec4 outputColor_S0 = vinColor_S0;
highp vec2 offset = vEllipseOffsets_S0;
highp float test = dot(offset, offset) - 1.0;
highp vec2 grad = (2.0 * offset) * vEllipseRadii_S0.xy;
highp float grad_dot = dot(grad, grad);
grad_dot = max(grad_dot, 1.1755e-38);
highp float invlen = (1.0 / sqrt(grad_dot));
highp float edgeAlpha = clamp(0.5 - test * invlen, 0.0, 1.0);
mediump vec4 outputCoverage_S0 = vec4(edgeAlpha);
{
gl_FragColor = outputColor_S0 * outputCoverage_S0;
}
}
