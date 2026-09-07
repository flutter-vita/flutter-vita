#version 100
precision mediump float;

highp float tf(highp float x) {
return 1.0 * x;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
