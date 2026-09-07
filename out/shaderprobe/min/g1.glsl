#version 100
precision mediump float;
highp float tf(highp float x) {
highp float q = 1.0;
return q * x;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
