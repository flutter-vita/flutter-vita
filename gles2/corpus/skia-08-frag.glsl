#version 100

precision mediump float;
precision mediump sampler2D;
uniform sampler2D uTextureSampler_0_S0;
varying mediump vec3 vinShadowParams_S0;
varying mediump vec4 vinColor_S0;
void main() {
mediump vec3 shadowParams = vinShadowParams_S0;
mediump vec4 outputColor_S0 = vinColor_S0;
mediump float d = length(shadowParams.xy);
highp vec2 uv = vec2(shadowParams.z * (1.0 - d), 0.5);
mediump float factor = texture2D(uTextureSampler_0_S0, uv, -0.475).w;
mediump vec4 outputCoverage_S0 = vec4(factor);
{
gl_FragColor = outputColor_S0 * outputCoverage_S0;
}
}
