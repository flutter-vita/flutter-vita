#version 100

precision mediump float;
precision mediump sampler2D;
varying mediump vec2 v_texCoord;
uniform sampler2D u_texture;
void main() {
gl_FragColor = texture2D(u_texture, v_texCoord);
}
