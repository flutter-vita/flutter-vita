#version 100
precision mediump float;
uniform highp float uTF[7];
highp float tf(highp float x) {
highp float s = sign(x);
highp float y = abs(x);
y = y < uTF[4] ? uTF[3] * y : pow(uTF[1] * y, uTF[0]);
return s * y;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
