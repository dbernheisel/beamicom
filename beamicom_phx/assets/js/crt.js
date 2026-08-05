// CRT filter for the WebRTC video: samples #videoPlayer into a WebGL2 texture
// each frame and renders it through a single-pass CRT shader into this canvas.
// The video stays in the DOM (covered, not display:none) so it keeps decoding
// and producing frames.
//
// If WebGL2 is unavailable the canvas hides itself and the plain video shows
// through — no filter, but the stream still plays.
//
// ── Shader attribution ──────────────────────────────────────────────────────
// The FRAG shader below is a GLSL ES 3.00 port of the "Public Domain CRT Styled
// Scan-line Shader" by Timothy Lottes (a.k.a. crt-lottes).
//
//   Author:  Timothy Lottes
//   Source:  https://github.com/libretro/slang-shaders/blob/master/crt/shaders/crt-lottes.slang
//            (originally published by the author on Shadertoy)
//   License: Public Domain — "Please take and use, change, or whatever."
//
// Changes from the original: translated Vulkan-GLSL → GLSL ES 3.00 for WebGL2,
// unused tunables trimmed, and `res` driven by the emulated NES resolution.

const VERT = `#version 300 es
in vec2 a_pos;
void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }`

// Ported from Timothy Lottes' public-domain CRT shader to GLSL ES 3.00.
// `res` is the *emulated* resolution (NES 256x240) — it drives scanline count,
// deliberately decoupled from the upscaled video texture's real dimensions.
const FRAG = `#version 300 es
precision highp float;
uniform sampler2D tex;
uniform vec2 resolution;   // output canvas size in device pixels
out vec4 fragColor;

const vec2 res = vec2(256.0, 240.0);
const float hardScan = -8.0;              // scanline hardness: -8 soft, -16 hard
const float hardPix = -3.0;               // horizontal pixel hardness
const vec2 warp = vec2(1.0/32.0, 1.0/24.0); // screen curvature
const float maskDark = 0.5;
const float maskLight = 1.5;

float ToLinear1(float c){return (c<=0.04045)?c/12.92:pow((c+0.055)/1.055,2.4);}
vec3 ToLinear(vec3 c){return vec3(ToLinear1(c.r),ToLinear1(c.g),ToLinear1(c.b));}
float ToSrgb1(float c){return (c<0.0031308)?c*12.92:1.055*pow(c,0.41666)-0.055;}
vec3 ToSrgb(vec3 c){return vec3(ToSrgb1(c.r),ToSrgb1(c.g),ToSrgb1(c.b));}

// Nearest emulated sample. Off-screen positions read black.
vec3 Fetch(vec2 pos, vec2 off){
  pos = floor(pos*res + off)/res;
  if(max(abs(pos.x-0.5), abs(pos.y-0.5)) > 0.5) return vec3(0.0);
  return ToLinear(texture(tex, pos).rgb);
}
vec2 Dist(vec2 pos){ pos = pos*res; return -((pos - floor(pos)) - vec2(0.5)); }
float Gaus(float pos, float scale){ return exp2(scale*pos*pos); }

vec3 Horz3(vec2 pos, float off){
  vec3 b=Fetch(pos,vec2(-1.0,off));
  vec3 c=Fetch(pos,vec2( 0.0,off));
  vec3 d=Fetch(pos,vec2( 1.0,off));
  float dst=Dist(pos).x;
  float wb=Gaus(dst-1.0,hardPix);
  float wc=Gaus(dst+0.0,hardPix);
  float wd=Gaus(dst+1.0,hardPix);
  return (b*wb+c*wc+d*wd)/(wb+wc+wd);
}
vec3 Horz5(vec2 pos, float off){
  vec3 a=Fetch(pos,vec2(-2.0,off));
  vec3 b=Fetch(pos,vec2(-1.0,off));
  vec3 c=Fetch(pos,vec2( 0.0,off));
  vec3 d=Fetch(pos,vec2( 1.0,off));
  vec3 e=Fetch(pos,vec2( 2.0,off));
  float dst=Dist(pos).x;
  float wa=Gaus(dst-2.0,hardPix);
  float wb=Gaus(dst-1.0,hardPix);
  float wc=Gaus(dst+0.0,hardPix);
  float wd=Gaus(dst+1.0,hardPix);
  float we=Gaus(dst+2.0,hardPix);
  return (a*wa+b*wb+c*wc+d*wd+e*we)/(wa+wb+wc+wd+we);
}
float Scan(vec2 pos, float off){ return Gaus(Dist(pos).y + off, hardScan); }

// Blend the nearest three scanlines.
vec3 Tri(vec2 pos){
  vec3 a=Horz3(pos,-1.0);
  vec3 b=Horz5(pos, 0.0);
  vec3 c=Horz3(pos, 1.0);
  return a*Scan(pos,-1.0) + b*Scan(pos,0.0) + c*Scan(pos,1.0);
}

vec2 Warp(vec2 pos){
  pos = pos*2.0 - 1.0;
  pos *= vec2(1.0 + (pos.y*pos.y)*warp.x, 1.0 + (pos.x*pos.x)*warp.y);
  return pos*0.5 + 0.5;
}

// Aperture-grille style shadow mask, spaced in output pixels.
vec3 Mask(vec2 pos){
  pos.x += pos.y*3.0;
  vec3 mask = vec3(maskDark);
  pos.x = fract(pos.x/6.0);
  if(pos.x < 0.333) mask.r = maskLight;
  else if(pos.x < 0.666) mask.g = maskLight;
  else mask.b = maskLight;
  return mask;
}

void main(){
  vec2 pos = Warp(gl_FragCoord.xy / resolution);
  vec3 col = Tri(pos) * Mask(gl_FragCoord.xy);
  fragColor = vec4(ToSrgb(col), 1.0);
}`

function compile(gl, type, src) {
  const sh = gl.createShader(type)
  gl.shaderSource(sh, src)
  gl.compileShader(sh)
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error("CRT shader: " + gl.getShaderInfoLog(sh))
  }
  return sh
}

const Crt = {
  mounted() {
    const canvas = this.el
    // Membrane's Player renders #videoPlayer asynchronously (see
    // prevent_game_key_scroll.js), so don't require it at mount — acquire it
    // lazily in the draw loop once it appears.
    this.video = null
    const gl = canvas.getContext("webgl2", {alpha: false, antialias: false})
    if (!gl) {
      canvas.style.display = "none" // fall back to the plain video underneath
      return
    }
    this.gl = gl

    const prog = gl.createProgram()
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT))
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG))
    gl.linkProgram(prog)
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      throw new Error("CRT link: " + gl.getProgramInfoLog(prog))
    }
    gl.useProgram(prog)
    this.resLoc = gl.getUniformLocation(prog, "resolution")

    // Fullscreen quad (two triangles).
    const buf = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buf)
    gl.bufferData(gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW)
    const posLoc = gl.getAttribLocation(prog, "a_pos")
    gl.enableVertexAttribArray(posLoc)
    gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 0, 0)

    this.texture = gl.createTexture()
    gl.bindTexture(gl.TEXTURE_2D, this.texture)
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true) // video row 0 -> canvas bottom, matches gl_FragCoord
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

    this.resize()
    this.observer = new ResizeObserver(() => this.resize())
    this.observer.observe(canvas)

    // Toggle: hide the canvas (video shows through) and skip GL work when off.
    this.enabled = true
    this.toggleBtn = document.getElementById("crt-toggle")
    if (this.toggleBtn) {
      this.onToggle = () => this.setEnabled(!this.enabled)
      this.toggleBtn.addEventListener("click", this.onToggle)
    }

    // ponytail: plain rAF loop. Robust to the late-appearing video; rVFC would
    // be a nicer per-frame pace but needs the video to exist first. Swap in if
    // 60fps texture uploads ever show up in a profile.
    this.draw = this.draw.bind(this)
    this.raf = requestAnimationFrame(this.draw)
  },

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const w = Math.round(this.el.clientWidth * dpr)
    const h = Math.round(this.el.clientHeight * dpr)
    if (w === this.el.width && h === this.el.height) return
    this.el.width = w
    this.el.height = h
    this.gl.viewport(0, 0, w, h)
    this.gl.uniform2f(this.resLoc, w, h)
  },

  setEnabled(on) {
    this.enabled = on
    this.el.style.visibility = on ? "" : "hidden"
    if (this.toggleBtn) this.toggleBtn.textContent = on ? "CRT filter: on" : "CRT filter: off"
  },

  draw() {
    if (!this.video) this.video = document.getElementById("videoPlayer")
    const {gl, video} = this
    if (this.enabled && video && video.readyState >= 2) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video)
      gl.drawArrays(gl.TRIANGLES, 0, 6)
    }
    this.raf = requestAnimationFrame(this.draw)
  },

  destroyed() {
    if (this.raf) cancelAnimationFrame(this.raf)
    this.observer?.disconnect()
    if (this.toggleBtn && this.onToggle) this.toggleBtn.removeEventListener("click", this.onToggle)
  }
}

export default Crt
