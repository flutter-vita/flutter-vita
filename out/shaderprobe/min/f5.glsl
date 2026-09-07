#version 100
precision mediump float;
uniform highp float uTF[7];
highp float tf(highp float x) {
highp float s = sign(x);
return s * x;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
