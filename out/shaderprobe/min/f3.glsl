#version 100
precision mediump float;
uniform highp float uTF[7];
highp float tf(highp float x) {
highp float G = uTF[0];
highp float A = uTF[1];
highp float B = uTF[2];
highp float C = uTF[3];
highp float D = uTF[4];
highp float E = uTF[5];
highp float F = uTF[6];
highp float s = sign(x);
x = abs(x);
x = x < D ? C * x + F : (A * x + B) + E;
return s * x;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
