#version 100
precision mediump float;
highp float tf(highp float y0) {
highp float s = 1.0;
return s * y0;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
