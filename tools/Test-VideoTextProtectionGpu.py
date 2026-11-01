"""Run production fill GLSL and the production gather/mask functions on desktop GL.
Only version headers and the desktop sampling harness differ; no algorithm rewrite.
"""
from pathlib import Path
import hashlib,json,re,sys
import numpy as np
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tmp/text-protection/python'))
import moderngl as gl
ctx=gl.create_standalone_context(require=430)
OUT=ROOT/'build/output/text-protection/gpu-review';OUT.mkdir(parents=True,exist_ok=True)
code=(ROOT/'native/render-bridge/render_bridge.cpp').read_text('utf-8')
def shader(name):
    s=re.search(r'constexpr const char\* '+name+r' = R"\((.*?)\)";',code,re.S).group(1)
    return re.sub(r'#version (300|310) es','#version 430',s)
common=shader('warp_common')
compute=[ctx.compute_shader(common+shader('warp_'+name)) for name in ['clear','scatter','classify']]
fill=ctx.program(vertex_shader=shader('vertex'),fragment_shader=shader('warp_frame_2d')+shader('warp_frame_body'))
w,h=640,352
yy,xx=np.mgrid[:h,:w];background=np.stack([(xx//4)%130+30,(yy//3)%110+40,(xx//5+yy//7)%90+50],axis=2).astype('u1')
image=Image.fromarray(background).convert('RGBA');draw=ImageDraw.Draw(image)
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',24)
text='硬字幕 Text protection';bounds=draw.textbbox((0,0),text,font=font,stroke_width=1)
x=(w-bounds[2])//2;y=270
draw.text((x,y),text,font=font,fill='white',stroke_width=1,stroke_fill='black')
rect=(x/w,(y+3)/h,(x+bounds[2])/w,(y+30)/h)
image.save(OUT/'source.png')
source=np.asarray(image)
near=np.where((xx//7)%2==0,225,25).astype('u1') # deliberately conflicting depths through every glyph
near[:,w//2: w//2+22]=255 # foreground across the subtitle
depth=ctx.texture((w*2,h),1,np.concatenate([near,near],axis=1).tobytes(),alignment=1)
depth.filter=(gl.LINEAR,gl.LINEAR);depth.repeat_x=False;depth.repeat_y=False
color=ctx.texture((w,h),4,source.tobytes(),alignment=1);color.filter=(gl.LINEAR,gl.LINEAR);color.repeat_x=False;color.repeat_y=False
keys=ctx.buffer(reserve=2*w*h*4);keys.bind_to_storage_buffer(0)
mapping=ctx.texture((w*2,h),4,dtype='f2');mapping.filter=(gl.NEAREST,gl.NEAREST);mapping.bind_to_image(0,read=False,write=True)
target=ctx.texture((w*2,h),4);fbo=ctx.framebuffer([target])
mask=(ROOT/'app/godot/shaders/text_protection.gdshaderinc').read_text('utf-8')
gather=(ROOT/'app/godot/shaders/video_rvm_pair.gdshader').read_text('utf-8')
oes=(ROOT/'app/godot/shaders/video_rvm_pair_oes.gdshader').read_text('utf-8')
def function(s,name):
    start=s.index(('float ' if name=='near_at' else 'vec2 ')+name+'(')
    at=s.index('{',start);level=1;end=at+1
    while level:
        level+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
for name in ['near_at','depth_parallax']:
    assert function(gather,name)==function(oes,name),'OES and 2D gather protection must match'
functions='\n'.join(function(gather,n) for n in ['near_at','depth_parallax'])
fragment='''#version 430
uniform sampler2D source;uniform sampler2D alpha_texture;
uniform vec2 source_size;uniform vec2 model_size;uniform vec4 model_content_rect;
uniform float depth_shift;uniform float depth_convergence;uniform int rotation_degrees;
vec2 raw_eye_uv(vec2 uv){return uv;}
out vec4 result;
'''+mask+'\n'+functions+'''
void main(){ivec2 o=ivec2(gl_FragCoord.xy);int eye=o.x>=int(source_size.x)?1:0;
vec2 shown=(vec2(o.x-eye*int(source_size.x),o.y)+0.5)/source_size;
result=texture(source,depth_parallax(shown,eye));}
'''
stretch=ctx.program(vertex_shader=shader('vertex'),fragment_shader=fragment)
def render_fill(enabled,shift,opacity=1.):
    depth.use(0)
    for stage,p in enumerate(compute):
        uniforms={'near_map':0,'size':(w,h),'model':(w,h),'content':(0,0,1,1),'shift':(w*shift/2,.35),
                  'count':2*w*h,'rim':max(2,int(w/120+.5)),'fg_win':max(2,int(w/240+.5)), 'text_count':int(enabled)}
        for k,v in uniforms.items():
            if k in p:p[k].value=v
        if 'text_regions' in p:p['text_regions'].write(np.array([rect]+[(0,0,0,0)]*7,'f4').tobytes())
        for key in ['text_weights0','text_weights1']:
            if key in p:p[key].value=(opacity,)*4
        p.run((2*w*h+255)//256 if stage==0 else ((w if stage==1 else 2*w)+7)//8,1 if stage==0 else (h+7)//8)
        ctx.memory_barrier()
    fbo.use();color.use(0);mapping.use(1)
    fill['source']=0;fill['map']=1;fill['size']=(w,h);fill['uv_scale']=(1,1)
    ctx.vertex_array(fill,[]).render(mode=gl.TRIANGLES,vertices=3);ctx.finish()
    return np.frombuffer(fbo.read(components=4,alignment=1),'u1').reshape(h,2*w,4)
def render_stretch(enabled,shift,opacity=1.):
    fbo.use();color.use(0);depth.use(1)
    for k,v in {'source':0,'alpha_texture':1,'source_size':(w,h),'model_size':(w,h),'model_content_rect':(0,0,1,1),
                'depth_shift':shift,'depth_convergence':.35,'depth_text_count':int(enabled)}.items():stretch[k]=v
    stretch['depth_text_regions'].write(np.array([rect]+[(0,0,0,0)]*7,'f4').tobytes())
    stretch['depth_text_weights0'].value=(opacity,)*4;stretch['depth_text_weights1'].value=(opacity,)*4
    ctx.vertex_array(stretch,[]).render(mode=gl.TRIANGLES,vertices=3);ctx.finish()
    return np.frombuffer(fbo.read(components=4,alignment=1),'u1').reshape(h,2*w,4)
reports=[]
roi=(slice(y+6,y+28),slice(x+2,x+bounds[2]-2))
for mode,render in [('fill',render_fill),('stretch',render_stretch)]:
    for shift in [.00875,.0175]:
        off=render(False,shift);on=render(True,shift);restored=render(False,shift)
        assert np.array_equal(off,restored),(mode,'disable must restore original')
        assert np.array_equal(off,render(True,shift,0.)),(mode,'zero opacity must preserve unprotected output')
        mid=render(True,shift,.5)
        assert not np.array_equal(mid,off) and not np.array_equal(mid,on),(mode,'fractional opacity must interpolate the actual displacement')
        errors=[]
        for eye in range(2):
            a=on[:,eye*w:(eye+1)*w,:3][roi].astype('f4');b=source[:,:,:3][roi].astype('f4')
            error=float(np.abs(a-b).mean());assert error<.15,(mode,shift,eye,error)
            errors.append(error)
        baseline=float(np.abs(off[:,:w,:3][roi].astype('f4')-source[:,:,:3][roi]).mean())
        assert baseline>1,(mode,'fixture must expose unprotected deformation')
        Image.fromarray(on).save(OUT/f'{mode}-{shift}-on.png');Image.fromarray(off).save(OUT/f'{mode}-{shift}-off.png')
        reports.append({'mode':mode,'shift':shift,'protected_mae_per_eye':errors,'unprotected_left_mae':baseline,'disable_restores':True})
# A flat-depth moving glyph fixture measures actual source-position steps, rather than colour fades.
# Same 33ms/240ms smoothstep progression as the render-time controller.
depth.write(np.full((h,w*2),230,'u1').tobytes())
weights=[]
for ms in [0,33,66,99,132,165,198,231,240]:
    t=min(1.,ms/240.);weights.append(t*t*(3-2*t))
fill_positions=[]
for weight in weights:
    render_fill(True,.0175,weight)
    table=np.frombuffer(mapping.read(alignment=1),'f2').reshape(h,w*2,4)
    fill_positions.append(float(table[y+16,w//2,0]))
sample_fragment=fragment.replace('result=texture(source,depth_parallax(shown,eye));','result=vec4(depth_parallax(shown,eye),0.0,1.0);')
sampler=ctx.program(vertex_shader=shader('vertex'),fragment_shader=sample_fragment)
float_target=ctx.texture((w*2,h),4,dtype='f4');float_fbo=ctx.framebuffer([float_target]);float_fbo.use()
depth.use(1)
for key,value in {'alpha_texture':1,'source_size':(w,h),'model_size':(w,h),'model_content_rect':(0,0,1,1),
                  'depth_shift':.0175,'depth_convergence':.35,'depth_text_count':1}.items():
    if key in sampler:sampler[key]=value
sampler['depth_text_regions'].write(np.array([rect]+[(0,0,0,0)]*7,'f4').tobytes())
gather_positions=[]
for weight in weights:
    sampler['depth_text_weights0'].value=(weight,)*4;sampler['depth_text_weights1'].value=(weight,)*4
    ctx.vertex_array(sampler,[]).render(mode=gl.TRIANGLES,vertices=3);ctx.finish()
    values=np.frombuffer(float_fbo.read(components=4,dtype='f4',alignment=1),'f4').reshape(h,w*2,4)
    gather_positions.append(float(values[y+16,w//2,0])*w-(w//2+.5))
temporal=[]
for mode,positions in [('fill',fill_positions),('gather',gather_positions)]:
    jump=abs(positions[-1]-positions[0]);step=max(abs(b-a) for a,b in zip(positions,positions[1:]))
    assert jump>2 and step<1.1,(mode,jump,step)
    temporal.append({'mode':mode,'hard_switch_px':jump,'max_transition_step_px':step,'positions_px':positions})
(OUT/'report.json').write_text(json.dumps({'gpu':ctx.info['GL_RENDERER'],'scope':'Desktop production shader functions; native GLES/OES transport and headset performance require device testing','cases':reports,'temporal':temporal,'native_shader_sha256':hashlib.sha256(code.encode()).hexdigest(),'mask_sha256':hashlib.sha256(mask.encode()).hexdigest()},indent=2),'utf-8')
print('Production fill/gather GPU: 4 endpoint/fractional cases plus 2 position-transition sequences passed')
