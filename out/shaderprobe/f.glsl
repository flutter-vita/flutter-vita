precision highp float;
varying vec2 vUV;
uniform sampler2D uTex;
highp float src_tf_S0_ff(highp float x) {
  highp float s = sign(x);
  x = abs(x);
  x = x < 0.04 ? 12.9 * x : pow(0.94 * x + 0.05, 2.4);
  return s * x;
}
void main() {
  vec4 c = texture2D(uTex, vUV.st);
  gl_FragColor = vec4(src_tf_S0_ff(c.s), src_tf_S0_ff(c.t), c.b, c.a);
}
