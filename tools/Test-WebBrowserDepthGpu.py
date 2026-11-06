"""Execute the production browser stereo shaders in a hidden Windows OpenGL context.

This validates shader compilation, eye ordering and canonical Y on the host GPU;
it does not replace Android SurfaceTexture/OpenXR or headset performance checks.
Outputs are regenerable under build/output/browser-depth.
"""
import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path
import re
import numpy as np


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / 'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserDepthBridge.kt').read_text(encoding='utf-8')
    shaders = [re.search(r'private const val ' + name + r' = """(.*?)"""', source, re.S)[1] for name in ['VERTEX', 'FRAGMENT']]
    user, gdi, ogl = c.WinDLL('user32'), c.WinDLL('gdi32'), c.WinDLL('opengl32')
    def bind(lib, name, result, *args):
        f = getattr(lib, name); f.restype = result; f.argtypes = args; return f
    create = bind(user, 'CreateWindowExW', w.HWND, w.DWORD,w.LPCWSTR,w.LPCWSTR,w.DWORD,c.c_int,c.c_int,c.c_int,c.c_int,w.HWND,w.HMENU,w.HINSTANCE,c.c_void_p)
    window = create(0, 'STATIC', 'Browser shader test', 0x80000000, 0, 0, 64, 32, None, None, None, None)
    dc = bind(user, 'GetDC', w.HDC, w.HWND)(window)
    class PFD(c.Structure):
        _fields_ = [('size',w.WORD),('version',w.WORD),('flags',w.DWORD)] + [(n,c.c_ubyte) for n in
            ['pixel','color','red','redShift','green','greenShift','blue','blueShift','alpha','alphaShift','accum','accumRed','accumGreen','accumBlue','accumAlpha','depth','stencil','aux','layer','reserved']] + [('layerMask',w.DWORD),('visible',w.DWORD),('damage',w.DWORD)]
    pfd = PFD(); pfd.size = c.sizeof(PFD); pfd.version = 1; pfd.flags = 0x24; pfd.color = 32; pfd.alpha = 8
    fmt = bind(gdi,'ChoosePixelFormat',c.c_int,w.HDC,c.POINTER(PFD))(dc,c.byref(pfd))
    assert fmt and bind(gdi,'SetPixelFormat',w.BOOL,w.HDC,c.c_int,c.POINTER(PFD))(dc,fmt,c.byref(pfd))
    context = bind(ogl,'wglCreateContext',c.c_void_p,w.HDC)(dc)
    current = bind(ogl,'wglMakeCurrent',w.BOOL,w.HDC,c.c_void_p)
    assert current(dc,context)
    address = bind(ogl,'wglGetProcAddress',c.c_void_p,c.c_char_p)
    def gl(name, result, *args):
        ptr = address(name.encode())
        if ptr and ptr not in (1,2,3,c.c_void_p(-1).value): return c.WINFUNCTYPE(result,*args)(ptr)
        return bind(ogl,name,result,*args)
    uint, integer, flt, ptr = c.c_uint,c.c_int,c.c_float,c.c_void_p
    get_string = gl('glGetString',c.c_char_p,uint)
    renderer = get_string(0x1F01).decode(); version = get_string(0x1F02).decode()
    create_shader = gl('glCreateShader',uint,uint)
    shader_source = gl('glShaderSource',None,uint,integer,c.POINTER(c.c_char_p),c.POINTER(integer))
    compile_shader = gl('glCompileShader',None,uint)
    get_shader = gl('glGetShaderiv',None,uint,uint,c.POINTER(integer))
    log = gl('glGetShaderInfoLog',None,uint,integer,c.POINTER(integer),c.c_char_p)
    compiled = []
    for kind,text in zip([0x8B31,0x8B30],shaders):
        shader = create_shader(kind); data = c.c_char_p(text.encode())
        shader_source(shader,1,c.byref(data),None); compile_shader(shader)
        ok = integer(); get_shader(shader,0x8B81,c.byref(ok))
        msg = c.create_string_buffer(8192); log(shader,len(msg),None,msg)
        assert ok.value, msg.value.decode(); compiled.append(shader)
    program = gl('glCreateProgram',uint)()
    attach = gl('glAttachShader',None,uint,uint)
    for shader in compiled: attach(program,shader)
    gl('glLinkProgram',None,uint)(program)
    ok = integer(); gl('glGetProgramiv',None,uint,uint,c.POINTER(integer))(program,0x8B82,c.byref(ok))
    assert ok.value, 'Program link failed'
    gl('glUseProgram',None,uint)(program)
    location = gl('glGetUniformLocation',integer,uint,c.c_char_p)
    uniform1i = gl('glUniform1i',None,integer,integer)
    uniform1f = gl('glUniform1f',None,integer,flt)
    uniform4f = gl('glUniform4f',None,integer,flt,flt,flt,flt)
    uniform4f(location(program,b'content'),0,0,1,1)
    uniform1i(location(program,b'color'),0); uniform1i(location(program,b'depth'),1)
    uniform1i(location(program,b'stereo_pair'),0)
    uniform1f(location(program,b'convergence'),.35)
    gen_tex = gl('glGenTextures',None,integer,c.POINTER(uint))
    bind_tex = gl('glBindTexture',None,uint,uint)
    param = gl('glTexParameteri',None,uint,uint,integer)
    image = gl('glTexImage2D',None,uint,integer,integer,integer,integer,integer,uint,uint,ptr)
    active = gl('glActiveTexture',None,uint)
    def texture(unit, pixels, internal=0x8058, external=0x1908, dtype=0x1401):
        tex=uint(); gen_tex(1,c.byref(tex)); active(0x84C0+unit); bind_tex(0x0DE1,tex)
        for key,value in [(0x2801,0x2601),(0x2800,0x2601),(0x2802,0x812F),(0x2803,0x812F)]: param(0x0DE1,key,value)
        image(0x0DE1,0,internal,pixels.shape[1],pixels.shape[0],0,external,dtype,pixels.ctypes.data)
        return tex
    color=np.zeros((32,64,4),dtype=np.uint8)
    color[:,:,0]=np.linspace(0,255,64,dtype=np.uint8)[None,:]
    color[:,:,1]=np.linspace(0,255,32,dtype=np.uint8)[:,None]; color[:,:,3]=255
    texture(0,color)
    texture(1,np.full((16,64),.8,dtype=np.float32),0x822E,0x1903,0x1406)
    output=texture(2,np.zeros((32,128,4),dtype=np.uint8))
    fbo=uint(); gl('glGenFramebuffers',None,integer,c.POINTER(uint))(1,c.byref(fbo))
    gl('glBindFramebuffer',None,uint,uint)(0x8D40,fbo)
    gl('glFramebufferTexture2D',None,uint,uint,uint,uint,integer)(0x8D40,0x8CE0,0x0DE1,output,0)
    assert gl('glCheckFramebufferStatus',uint,uint)(0x8D40)==0x8CD5
    vao=uint(); gl('glGenVertexArrays',None,integer,c.POINTER(uint))(1,c.byref(vao)); gl('glBindVertexArray',None,uint)(vao)
    gl('glViewport',None,integer,integer,integer,integer)(0,0,128,32)
    draw=gl('glDrawArrays',None,uint,integer,integer)
    read=gl('glReadPixels',None,integer,integer,integer,integer,uint,uint,ptr)
    def render(shift):
        uniform1f(location(program,b'shift'),shift); draw(4,0,3)
        pixels=np.empty((32,128,4),dtype=np.uint8); read(0,0,128,32,0x1908,0x1401,pixels.ctypes.data)
        assert gl('glGetError',uint)()==0
        return pixels
    flat=render(0)
    assert np.max(abs(flat[:,:64].astype(int)-flat[:,64:].astype(int)))<=1, 'Mono eye mismatch'
    assert flat[0,32,1]>240 and flat[-1,32,1]<15, 'Canonical top row was inverted'
    stereo=render(.1)
    delta=float(np.mean(stereo[4:-4,80:112,0].astype(float)-stereo[4:-4,16:48,0]))
    assert 9<delta<14, f'Incorrect near disparity or eye order: {delta}'
    assert np.all(stereo[:,:,3]==255), 'Depth unexpectedly changed alpha'
    pair=np.zeros((32,128,4),dtype=np.uint8); pair[:,:64,0]=200; pair[:,64:,2]=220; pair[:,:,3]=255
    texture(0,pair); uniform1i(location(program,b'stereo_pair'),1)
    packed=render(0)
    assert np.all(packed[:,:64,0]==200) and np.all(packed[:,:64,2]==0) and np.all(packed[:,64:,2]==220) and np.all(packed[:,64:,0]==0), 'Prewarped eyes crossed their halves'
    report={'renderer':renderer,'version':version,'checks':['production ES shaders compile/link','mono eyes match','canonical top row','near disparity and eye order','opaque output','prewarped eye halves'], 'near_disparity_red_delta':delta,'passed':True}
    out=root/'build/output/browser-depth'; out.mkdir(parents=True,exist_ok=True)
    (out/'gpu-shader.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report))
    current(None,None); bind(ogl,'wglDeleteContext',w.BOOL,c.c_void_p)(context)
    bind(user,'ReleaseDC',c.c_int,w.HWND,w.HDC)(window,dc); bind(user,'DestroyWindow',w.BOOL,w.HWND)(window)

if __name__=='__main__': main()
