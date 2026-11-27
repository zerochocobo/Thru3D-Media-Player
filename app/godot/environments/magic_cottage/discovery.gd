extends RefCounted
## The two journals outlive visits. Only the living specimen and unfinished pot are per visit.
const MATERIALS := ["绯露", "潮汐瓶", "金琥液", "紫晶", "卷蕨", "日珠"]
const EFFECTS := ["失重潮","窥星巨瞳","星海坍缩","极光帷幕","金蛾夜游","霜花蔓延","流星骤雨","逆行天球","荧藤苏醒","萤灯巡礼",
	"炉心飞火","六枝雪印","分岔惊雷","回声铜铃","墙上蔷薇","织星笔","藏书旋风","双扉引蝶","游鱼引灵","归杖月轮"]
const VERSES := ["屋中的一切与旅人一同浮起","窗外睁开一只巨大的眼睛","群星爆开，卷入黑洞","极光像丝带一样滑过双窗","金色飞蛾绕着炉火起舞","冰晶沿两扇窗棂生长","流星雨划过夜空","星图倒转，星辰逆流","荧光藤蔓从墙脚舒展","一列琥珀灯在空中巡游",
	"指墙扣动扳机\n火球撞成一圈余烬","点过的地方\n长出六瓣冰花","杖尖引出折电\n落点再分数枝","点墙悬铃\n点得越高音越高","点墙播种\n蔷薇攀石而开",
	"点下几颗星\n依次连成星座","点出一道旋风\n卷起散落书页","点两处开门\n金蝶从彼端飞出","按住引鱼随杖\n松手游向落点","点出一弯新月\n去而复归杖尖"]
const SPECIES := ["月纱铃兰","银脊卷蕨","追星鸢尾","灯市绯伞","衔月藤","潮汐石莲","流萤酸浆","霜镜兰","夜渡睡莲","星烛鹿角木"]
const FULL := 3600000
const MIDDLE := 1200000
# Dense, cold and mutually volatile mixtures can sputter on the first attempt.
const VOLATILE := ["013","024","035"]
# The ten original apparitions retain one recipe each. The other ten now enchant the wand.
const FORMULAS := {
	"012":0,"013":7,"014":4,"015":1,"023":6,"024":3,"025":10,"034":5,"035":2,"045":14,
	"123":11,"124":8,"125":13,"134":16,"135":12,"145":18,"234":15,"235":9,"245":17,"345":19
}
var herbs := {}
var recipes := {}
var sputtered := {}
var attempts := 0
var failures := 0
var unlocked_at := 0
var generation := 0
var directory := "user://magic_cottage"
var keys: Array[String] = []
var species := 0
var effective_ms := 0
var last_ms := 0
var wet := false
var stage := 0
var batch: Array[int] = []

func _init() -> void:
	keys.assign(FORMULAS.keys())

func load_journals() -> void:
	for slot in 2:
		var file := ConfigFile.new()
		if file.load(directory + "/journal%d.cfg" % slot) != OK: continue
		var revision := int(file.get_value("archive","revision",0))
		if revision <= generation: continue
		generation = revision
		herbs = file.get_value("archive","herbs",{})
		if int(file.get_value("archive","plant_edition",1))<2:
			var revised := {}
			for old in herbs:
				if int(old)>=0 and int(old)<50: revised[floori(float(old)/5.)]=true
			herbs=revised
		recipes = file.get_value("archive","recipes",{})
		sputtered = file.get_value("archive","sputtered",{})
		attempts = int(file.get_value("archive","attempts",0))
		failures = int(file.get_value("archive","failures",0))
		unlocked_at = int(file.get_value("archive","unlocked_at",0))

	# Older journals allowed repeated doses. Project their discoveries onto today's shelf.
	for key in recipes.keys():
		if FORMULAS.has(key): recipes[key] = effect(key)
		else: recipes.erase(key)
	for key in sputtered.keys():
		if key not in VOLATILE: sputtered.erase(key)

func save() -> void:
	if directory.is_empty(): return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var file := ConfigFile.new()
	var revision := generation+1
	for field in ["herbs","recipes","sputtered","attempts","failures","unlocked_at"]:
		file.set_value("archive",field,get(field))
	file.set_value("archive","revision",revision)
	file.set_value("archive","plant_edition",2)
	if file.save(directory + "/journal%d.cfg" % (revision%2)) == OK: generation = revision
	else: push_error("Could not save cottage journals")

func enter(now: int, wall_time: int) -> void:
	var pool: Array[int] = []
	for id in SPECIES.size():
		if not herbs.has(id): pool.append(id)
	species = randi_range(0,SPECIES.size()-1) if pool.is_empty() else pool.pick_random()
	last_ms = now
	effective_ms = 0
	stage = 0
	wet = false
	batch.clear()
	if unlocked_at == 0:
		unlocked_at = wall_time
		save()

func advance(now: int) -> bool:
	effective_ms = mini(FULL,effective_ms+maxi(0,now-last_ms)*(2 if wet else 1))
	last_ms = now
	var next := 2 if effective_ms >= FULL else 1 if effective_ms >= MIDDLE else 0
	if next == stage: return false
	stage = next
	if stage == 2 and not herbs.has(species):
		herbs[species] = true
		save()
	return true

func water(now: int) -> void:
	advance(now)
	wet = true

func effect(key: String) -> int:
	return FORMULAS.get(key,-1)

func add_dose(id: int, wall_time: int) -> Dictionary:
	if id < 0 or id >= MATERIALS.size() or id in batch: return {}
	batch.append(id)
	if batch.size() < 3: return {}
	batch.sort()
	var key := "%d%d%d" % batch
	batch.clear()
	attempts += 1
	var failed := key in VOLATILE and not recipes.has(key) and not sputtered.has(key) and (failures+1)*5 <= attempts
	if failed:
		failures += 1
		sputtered[key] = true
	var discovery := not failed and not recipes.has(key)
	if discovery:
		recipes[key] = effect(key)
		unlocked_at = wall_time
	save()
	return {"key":key, "effect":-1 if failed else effect(key), "new":discovery}

func hints(wall_time: int) -> Array:
	var out := []
	var overdue := wall_time-unlocked_at > 3600
	# Stable until a new discovery. The first lead of the next visit stays put.
	for k in keys.size():
		var key := keys[((k+recipes.size())*23+9)%keys.size()]
		if recipes.has(key): continue
		out.append({"key":key,"visible":2 if overdue and out.is_empty() else 1})
		if out.size() >= (2 if overdue else 1): break
	return out
