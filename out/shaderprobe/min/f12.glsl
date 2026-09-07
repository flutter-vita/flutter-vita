#version 100
precision mediump float;

highp float tf(highp float x) {
mediump float s = 1.0;
return s * x;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
