extends SceneTree
const Timing := preload("res://scripts/file_audio_timing.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
 var accepted := true
 var delays: Array = []
 func set_mpv_audio(_id: int, _track: int, _volume: float, _muted: bool) -> bool: return accepted
 func set_mpv_audio_delay(id: int, value: float) -> bool: delays.append([id,value]); return accepted
 func close_mpv_video(_id: int) -> void: pass
func check(ok: bool, text: String) -> void:
 checks += 1
 if not ok: failures.append(text)
func _initialize() -> void: call_deferred("run")
func run() -> void:
 var directory := ProjectSettings.globalize_path("res://../../build/output/audio-sync-test/" + str(Time.get_ticks_usec()))
 var store := Timing.new(directory)
 var video := Video.new();root.add_child(video);video.set_process(false)
 video.audio_timing=store;video.local_uri="file:///audio-sync/movie.mp4";video._remember_file=true
 var host := Host.new();video.platform=host;video.media.begin(7);video.media.state="playing"
 video.media.playback={"details":{"audio_tracks":[{"id":1,"title":"Original"},{"id":3,"external":true,"title":"movie.chs.m4a"}]}}
 check(video.select_audio_track(1),"Original track accepted")
 var original: String=video.audio_timing_key()
 check(video.commit_audio_delay(.15,video.local_uri,original) and is_equal_approx(video.audio_delay,.15),"50ms precision reaches native and persists")
 check(video.select_audio_track(3) and is_zero_approx(video.audio_delay),"Dubbed track starts with its own correction")
 var dubbed: String=video.audio_timing_key()
 check(video.commit_audio_delay(-.25,video.local_uri,dubbed),"Negative correction accepted")
 check(video.select_audio_track(1) and is_equal_approx(video.audio_delay,.15),"Returning to original restores its correction")
 var sent := host.delays.size()
 check(video.commit_audio_delay(.35,video.local_uri,dubbed) and host.delays.size()==sent and is_equal_approx(video.audio_delay,.15),"Old captured track saves without shifting current track")
 var loaded:=Timing.new(directory)
 loaded.load_saved()
 check(is_equal_approx(loaded.for_track(video.local_uri,dubbed),.35),"Track corrections survive reload")
 host.accepted=false
 check(not video.set_audio_delay(.5) and is_equal_approx(video.audio_delay,.15),"Rejected native request leaves current value")
 host.accepted=true
 check(not video.set_audio_delay(NAN),"Non-finite correction rejected")
 check(is_equal_approx(Timing.delay(11),10) and is_equal_approx(Timing.delay(-11),-10),"Range clamps at ten seconds")
 check(Timing.track_key({"id":3,"title":"movie.chs.m4a","external":true})==Timing.track_key({"id":8,"title":"movie.chs.m4a","external":true}),"External timing follows filename across runtime track IDs")
 var main:=Main.new();main.video=video;main.settings_path=directory.path_join("settings.cfg")
 var menu:=Menu.new();main.player_menu=menu;menu.state_provider=main._menu_state;menu.setting_requested.connect(main._on_player_setting)
 root.add_child(menu);menu.toggle();menu.set_process(false);menu._audio_open=true;menu._audio_source=video.local_uri;menu.refresh()
 var plus: int=-1
 for target in menu.choices.targets:
  var item: Dictionary=menu.choices.targets[target]
  if item.kind=="nudge" and item.key=="audio_delay" and item.step>0:plus=target
 check(plus>=0,"Audio panel has time nudge")
 menu.choices.action(plus)
 check(is_equal_approx(video.audio_delay,.2),"Plus nudges by 50ms, not 100ms")
 for slider in menu.choices.sliders.values():
  if slider.get("signed",false): check(slider.label.text=="+0.20 s","Signed hundredths visible")
 menu.free();main.free();video.free()
 print("Audio sync checks=%d failures=%d"%[checks,failures.size()])
 for failure in failures:push_error(failure)
 quit(0 if failures.is_empty() else 1)
