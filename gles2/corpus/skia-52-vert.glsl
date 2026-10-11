#version 100

precision mediump float;
precision mediump sampler2D;
attribute mediump vec2 a_vertex;
uniform mediump vec4 u_texCoordXform;
uniform mediump vec4 u_posXform;
varying mediump vec2 v_texCoord;
void main() {
v_texCoord = a_vertex * u_texCoordXform.xy + u_texCoordXform.zw;
gl_Position.xy = a_vertex * u_posXform.xy + u_posXform.zw;
gl_Position.zw = vec2(0.0, 1.0);
}
