"""Editable furnishings and animated sky of the seated star workshop."""
import math
import bpy
from pathlib import Path
from hall_mesh import block, collection, lathe, line, material, mesh, oval, packed_image


def sofa():
    collection("South wall | tapestry settle")
    cloth = material("Madder coverlet", (1, 1, 1), .96)
    shader = cloth.node_tree.nodes["Principled BSDF"]
    shader.inputs["Sheen Weight"].default_value = .28
    image = cloth.node_tree.nodes.new("ShaderNodeTexImage")
    image.image = packed_image(Path(__file__).resolve().parents[2] / "build/magic-cottage-design/coverlet.jpg")
    cloth.node_tree.links.new(image.outputs["Color"], shader.inputs["Base Color"])

    # Longitudinal section of one uncut throw, rear hem -> crest -> lap -> front hem.
    # Each third component lifts the material where it passes over either bolster.
    section = [
        (-2.272,.060,0),(-2.274,.51,0),(-2.267,1.05,0),(-2.239,1.245,0),
        (-2.184,1.281,0),(-2.135,1.254,0),(-2.104,1.165,0),(-2.076,1.02,.08),
        (-2.038,.843,.23),(-2.005,.692,.56),(-1.961,.583,.90),(-1.907,.568,1.00),
        (-1.83,.576,1.00),(-1.72,.590,.97),(-1.595,.607,.88),(-1.508,.6,.71),
        (-1.459,.574,.54),(-1.432,.516,.37),(-1.421,.405,.14),(-1.426,.267,.05),
        (-1.426,.145,0),(-1.421,.075,0)]
    def point(u, t):
        cursor = t * (len(section)-1)
        index = min(int(cursor),len(section)-2)
        f = cursor-index
        a,b,c,d = [section[min(max(j,0),len(section)-1)] for j in (index-1,index,index+1,index+2)]
        y,z,arm = [(.5*((2*b[k])+(-a[k]+c[k])*f+
                    (2*a[k]-5*b[k]+4*c[k]-d[k])*f*f+(-a[k]+3*b[k]-3*c[k]+d[k])*f**3)) for k in range(3)]
        across = abs(u)
        # The last handspan drops over the sides and gathers at the corners.
        edge = min(1,max(0,(across-.82)/.18))
        fall = edge*edge*(3-2*edge)
        x = math.copysign(1.19*min(across/.83,1) + .135*edge, u)
        roll = math.exp(-((across-.772)/.092)**2)
        z += .255*roll*arm + .037*(1-u*u)*math.exp(-((t-.20)/.14)**2)
        z -= .019*math.exp(-((u+.11)/.31)**2)*arm
        low = .046+.021*(.5+.5*math.sin(9*u+2.2*t))+.011*math.sin(25*t+u)
        z = z*(1-fall)+low*fall
        ripple = math.sin(32*u+3.8*t+1.3*math.sin(8*u))+.36*math.sin(63*u-5*t)
        front = max(0,(t-.72)/.28)
        back = math.exp(-((t-.33)/.105)**2)
        y += ripple*(.026*front+.009*back)*(1-.53*edge)
        x += math.copysign(.024*fall*math.sin(36*t+1.7*math.cos(14*t)),u)
        z += (.009*math.sin(22*u+19*t)+.006*math.sin(41*u-10*t))*arm*(1-fall)
        z += .022*front*front*(1+math.sin(15*u+.57))
        return x,y,z

    cols, rows = 104, 66
    verts = [point(2*i/cols-1,j/rows) for j in range(rows+1) for i in range(cols+1)]
    faces = [(i,i+1,i+cols+2,i+cols+1) for j in range(rows) for i in range(j*(cols+1),j*(cols+1)+cols)]
    throw = mesh("Whole woven wool coverlet", verts, faces, cloth)
    uv = throw.data.uv_layers.new(name="Flat loom layout")
    for loop in throw.data.loops:
        j,i = divmod(loop.vertex_index,cols+1)
        uv.data[loop.index].uv=(i/cols,1-j/rows)
    for face in throw.data.polygons:
        face.use_smooth = True
    # Hand-knotted warp ends follow the low, gently uneven front edge.
    flax = material("Wool fringe",(.36,.19,.073),.97)
    for knot in range(53):
        u = -.88+1.76*knot/52
        x,y,z=point(u,1.)
        for k in (-1,0,1):
            dx=.0028*k
            line("Warp end",[(x+dx,y,z+.003),(x+dx,y+.002,z-.009),
                             (x+dx*1.8+.002*math.sin(knot),y+.004,z-.030-.003*math.cos(knot+k))],.0017,flax)


def sky(scene, mirror, atlas):
    world=bpy.data.worlds.new("Cold star field")
    scene.world=world
    world.use_nodes=True
    nodes,links=world.node_tree.nodes,world.node_tree.links
    noise=nodes.new("ShaderNodeTexVoronoi")
    noise.inputs["Scale"].default_value=240
    links.new(nodes.new("ShaderNodeTexCoord").outputs["Normal"],noise.inputs[0])
    ramp=nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position=.025
    ramp.color_ramp.elements[0].color=(2,2.5,4,1)
    ramp.color_ramp.elements[1].position=.107
    ramp.color_ramp.elements[1].color=(.012,.024,.060,1)
    links.new(noise.outputs["Distance"],ramp.inputs[0])
    links.new(ramp.outputs[0],nodes["Background"].inputs[0])
    mat=mirror.data.materials[0]
    nodes,links=mat.node_tree.nodes,mat.node_tree.links
    tex=nodes.new("ShaderNodeTexImage")
    tex.image=packed_image(atlas)
    uv=mirror.data.uv_layers.new()
    for loop in mirror.data.loops:
        p=mirror.data.vertices[loop.vertex_index].co
        uv.data[loop.index].uv=((p.x+2.65)/5.30,(p.z-.12)/4.42)
    mapping=nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value=(.124,.124,1)
    for axis,expression in enumerate(["((floor((frame-1)/165)*17)%8)/8+.0005","(7-(floor((frame-1)/165)*17//8)%8)/8+.0005"]):
        mapping.inputs["Location"].driver_add("default_value",axis).driver.expression=expression.replace("//8","/8") if axis==0 else "(7-floor(((floor((frame-1)/165)*17)%64)/8))/8+.0005"
    links.new(nodes.new("ShaderNodeTexCoord").outputs["UV"],mapping.inputs["Vector"])
    links.new(mapping.outputs[0],tex.inputs[0])
    shader=nodes["Principled BSDF"]
    links.new(tex.outputs[0],shader.inputs["Base Color"])
    links.new(tex.outputs[0],shader.inputs["Emission Color"])
    shader.inputs["Emission Strength"].default_value=1.7


def furnishings(oak, brass, iron, clay, paper):
    glass=material("Antique crown glass",(.18,.35,.48),.12)
    glass.node_tree.nodes["Principled BSDF"].inputs["Transmission Weight"].default_value=.94
    glass.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value=.14
    collection("Glazing")
    for centre in (-3.5,3.5):
        block("Glazed lancet",(centre,5.13,1.99),(1.24,.018,2.55),glass)
        for dx in (-.32,.32):
            block("Leaded came",(centre+dx,5.10,1.91),(.014,.02,2.39),iron)
        for z in (1.48,2.25):
            block("Leaded crossbar",(centre,5.10,z),(1.24,.02,.016),iron)
    collection("Jug")
    x,y,z=4.00,3.04,1.13
    glaze=material("Woad-blue salt glaze",(.059,.21,.32),.25)
    lathe("Blue water ewer",(x,y,z),[(.11,0),(.16,.05),(.17,.18),(.12,.28),(.085,.34),(.11,.39),(.086,.39)],glaze)
    line("Ewer handle",[(x,y+.10,z+.31),(x,y+.22,z+.34),(x,y+.255,z+.24),(x,y+.22,z+.15),(x,y+.15,z+.13)],.029,glaze)
    line("Pouring lip",[(x,y-.06,z+.31),(x,y-.15,z+.36),(x,y-.19,z+.40)],.045,glaze)
    collection("Kettle")
    x,y=3.96,.94
    block("Low hearthstone",(x,y,.12),(.99,1.10,.24),iron,.07)
    for k in range(4):
        log=block("Charred split log",(x+.15*math.cos(k*1.57),y+.14*math.sin(k*1.57),.32),(.15,.64,.12),oak,.04)
        log.rotation_euler.z=k*.85
    lathe("Bellied cast cauldron",(x,y,.49),[(.19,0),(.32,.055),(.415,.22),(.41,.42),(.33,.57),(.37,.59),(.37,.63),(.315,.63),(.30,.55)],iron)
    liquid=material("Luminous decoction",(.16,.50,.29),.22,glow=.9)
    oval("Witch broth",(x,y,1.075),(.318,.318,.018),liquid)
    for sign in (-1,1):
        line("Cauldron lug",[(x,y+sign*.34,.89),(x,y+sign*.47,.94),(x,y+sign*.50,.82),(x,y+sign*.37,.78)],.029,brass)
    fire=material("Peat fire",(.98,.22,.025),.35,glow=3.5)
    collection("Fire")
    for i in range(9):
        a=i*2.4
        flame=lathe("Peat flame",(x+.25*math.cos(a),y+.25*math.sin(a),.33),[(.038,0),(.066,.055),(.058,.115),(.030,.19),(.014,.24+i%3*.018),(0,.285+i%3*.018)],fire,9)
        flame.rotation_euler.y=.22*math.sin(a)
    profiles=[[(.10,0),(.145,.06),(.13,.19),(.052,.27),(.051,.36),(.073,.38)],
              [(.10,0),(.115,.04),(.105,.28),(.052,.32),(.05,.41),(.06,.42)],
              [(.09,0),(.15,.11),(.155,.23),(.07,.28),(.068,.32),(.08,.33)]]
    colors=[(.50,.09,.15),(.08,.36,.40),(.51,.28,.045),(.30,.12,.55),(.09,.40,.23),(.63,.44,.11)]
    for i,color in enumerate(colors):
        collection("Dose"+str(i))
        x,y,z=4.10,1.86+i*.46,2.31
        mat=material(["Garnet cordial","Tideglass","Amber flask","Amethyst shard","Fern whorl","Sun pearl"][i],color,.26,.15,.25)
        if i<3:
            profile=profiles[i]
            lathe("Potion flask",(x,y,z),profile,mat,16 if i!=1 else 7)
            h=profile[-1][1]
            lathe("Honeywax seal",(x,y,z+h),[(.045,0),(.057,.035)],oak)
            lathe("Gold neck thread",(x,y,z+h-.035),[(.063,0),(.063,.012)],brass)
        elif i==3:
            for j in range(3):
                shard=lathe("Cut amethyst",(x,y+(j-1)*.06,z),[(.04,0),(.062,.09),(.058,.23+j*.03),(0,.34+j*.035)],mat,5)
                shard.rotation_euler.x=(j-1)*.24
        elif i==4:
            for j in range(5):
                leaf=oval("Coiled fiddlehead",(x,y+(j-2)*.039,z+.13+(.06 if j==2 else 0)),(.037,.050,.143),mat)
                leaf.rotation_euler.x=(2-j)*.30
        else:
            oval("Golden pearl",(x,y,z+.13),(.12,.12,.12),mat)
            for j in range(2):
                line("Celestial orbit",[(x+.14*math.cos(a*.131),y+.14*math.sin(a*.131)*j,z+.13+.14*math.sin(a*.131)*(1-j)) for a in range(48)],.009,brass,True)
    collection("Recipe")
    x,y,z=-3.99,1.99,2.23
    block("Gospel stand foot",(x,y,2.038),(.30,.50,.035),oak,.012)
    hide=material("Plum recipe binding",(.22,.055,.19),.75)
    block("Alchemist folio",(x,y,z),(.12,.37,.41),paper,.012)
    for dx in (-.072,.072):
        block("Plum leather",(x+dx,y,z),(.023,.40,.44),hide,.012)
    line("Gilded retort",[(x+.086,y-.075,z-.10),(x+.086,y+.075,z-.10),(x+.086,y+.052,z-.015),(x+.086,y+.018,z+.04),(x+.086,y+.018,z+.12),(x+.086,y-.016,z+.12),(x+.086,y-.016,z+.04),(x+.086,y-.075,z-.10)],.009,brass)
