#version 100

precision mediump float;
precision mediump sampler2D;
uniform sampler2D uTextureSampler_0_S0;
varying highp vec2 vlocalCoord_S0;
varying highp float vcoverage_S0;
void main() {
mediump vec4 outputColor_S0 = vec4(1.0);
highp vec2 texCoord = vlocalCoord_S0;
outputColor_S0 = texture2D(uTextureSampler_0_S0, texCoord, -0.475);
highp float coverage = vcoverage_S0;
mediump vec4 outputCoverage_S0 = vec4(coverage);
{
gl_FragColor = outputColor_S0 * outputCoverage_S0;
}
}
