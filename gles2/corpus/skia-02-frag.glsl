#version 100

precision mediump float;
precision mediump sampler2D;
varying mediump vec4 vcolor_S0;
void main() {
mediump vec4 outputColor_S0 = vcolor_S0;
{
gl_FragColor = outputColor_S0;
}
}
