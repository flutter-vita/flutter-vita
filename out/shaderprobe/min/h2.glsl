#version 100
precision mediump float;
highp float tf(highp float y0) {
highp float t = 1.0;
return t * y0;
}
void main() { gl_FragColor = vec4(tf(0.5)); }
