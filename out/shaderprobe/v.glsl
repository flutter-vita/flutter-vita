attribute vec4 aPos;
varying vec2 vUV;
void main() {
  vUV = aPos.st;
  gl_Position = aPos;
}
