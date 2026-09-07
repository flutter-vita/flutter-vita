#version 100
precision mediump float;
highp float tf(highp float x) {
highp float s = x;
return s;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
