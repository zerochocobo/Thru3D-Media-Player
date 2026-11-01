"""Check template installation, idempotence and fail-closed handling of host changes."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("prepare_android_host", ROOT / "tools/environment/prepare_android_host.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
TEMPLATE = """package com.godot.game;
public class GodotApp extends GodotActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        SplashScreen.installSplashScreen(this);
        super.onCreate(savedInstanceState);
    }
}
"""


class AndroidHostGuardTest(unittest.TestCase):
    def test_real_guard_blocks_exported_controls_and_preserves_internal_restart(self):
        # Small API doubles execute our actual Java guard; Android framework/XR still needs a device.
        sources = {
            "android/os/Bundle.java": "package android.os; public class Bundle {}",
            "android/content/ComponentName.java": "package android.content; public class ComponentName {}",
            "android/content/pm/ApplicationInfo.java": "package android.content.pm; public class ApplicationInfo { public int uid; }",
            "android/content/pm/ActivityInfo.java": "package android.content.pm; public class ActivityInfo { public boolean exported; public ApplicationInfo applicationInfo = new ApplicationInfo(); }",
            "android/content/pm/PackageManager.java": """package android.content.pm;
public class PackageManager {
 public ActivityInfo info; public boolean missing;
 public ActivityInfo getActivityInfo(android.content.ComponentName name, int flags) throws NameNotFoundException {
  if(missing) throw new NameNotFoundException(); return info;
 }
 public static class NameNotFoundException extends Exception {}
}""",
            "android/app/Activity.java": """package android.app;
public class Activity {
 public android.content.pm.PackageManager pm = new android.content.pm.PackageManager();
 public android.content.pm.ApplicationInfo app = new android.content.pm.ApplicationInfo();
 public android.content.pm.PackageManager getPackageManager() {return pm;}
 public android.content.pm.ApplicationInfo getApplicationInfo() {return app;}
}""",
            "android/content/Intent.java": """package android.content;
public class Intent {
 public ComponentName target = new ComponentName(); public boolean poisoned;
 public java.util.Map<String,Object> extras = new java.util.HashMap<>();
 public ComponentName getComponent() {return target;}
 public void removeExtra(String key) {if(poisoned) throw new IllegalStateException(); extras.remove(key);}
 public Intent replaceExtras(android.os.Bundle b) {extras.clear(); poisoned=false; return this;}
}""",
            "com/godot/game/GuardHarness.java": """package com.godot.game;
public class GuardHarness {
 static void check(boolean result) {if(!result) throw new AssertionError("launch guard behavior");}
 public static void main(String[] args) {
  for(int scenario=0;scenario<6;scenario++) {
   android.app.Activity host = new android.app.Activity(); host.app.uid=100;
   host.pm.info=new android.content.pm.ActivityInfo(); host.pm.info.applicationInfo.uid=100;
   host.pm.info.exported=scenario==0; host.pm.missing=scenario==3;
   if(scenario==2) host.pm.info.applicationInfo.uid=200;
   android.content.Intent intent=new android.content.Intent();
   if(scenario==4) intent.target=null;
   if(scenario==5) {host.pm.info.exported=true; intent.poisoned=true;}
   intent.extras.put("new_launch_requested",true); intent.extras.put("command_line_params",new String[]{"--quit"});
   intent.extras.put("unrelated","preserve");
   check(GodotLaunchIntentGuard.sanitize(host,intent)==intent);
   check(intent.extras.containsKey("new_launch_requested")== (scenario==1));
   check(intent.extras.containsKey("command_line_params")== (scenario==1));
   check(intent.extras.containsKey("unrelated")== (scenario!=5));
  }
  check(GodotLaunchIntentGuard.sanitize(new android.app.Activity(),null)==null);
 }
}""",
        }
        self.assertIsNotNone(shutil.which("javac"), "Activate the project JDK before running this check")
        output = ROOT / "build/output/external-playback/host-guard-unit"
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory:
            temporary = Path(directory)
            inputs = []
            for name, text in sources.items():
                path = temporary / name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8"); inputs.append(str(path))
            inputs.append(str(ROOT / "android/host/GodotLaunchIntentGuard.java"))
            compiled = subprocess.run(["javac", "-encoding", "UTF-8", "-d", str(output), *inputs], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run(["java", "-cp", str(output), "com.godot.game.GuardHarness"], capture_output=True, text=True)
            self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_filter_runs_before_parent_and_before_splash(self):
        result = MODULE.patched_host(TEMPLATE)
        self.assertLess(result.index(MODULE.CREATE), result.index("SplashScreen.install"))
        self.assertLess(result.index(MODULE.CREATE), result.index("super.onCreate"))
        self.assertEqual(result.count(MODULE.NEW_INTENT), 1)
        self.assertEqual(MODULE.patched_host(result), result)

    def test_unknown_or_partially_overwritten_hosts_are_rejected(self):
        for source in (TEMPLATE.replace("public void onCreate", "protected void onCreate"),
                       TEMPLATE.replace("GodotActivity", "OtherActivity"),
                       TEMPLATE.replace("\n}", "\n protected void onNewIntent(Intent i) {}\n}"),
                       MODULE.patched_host(TEMPLATE).replace(MODULE.NEW_INTENT, "super.onNewIntent(intent);")):
            with self.subTest(source=source), self.assertRaises(ValueError):
                MODULE.patched_host(source)

    def test_reinstalling_template_reapplies_persistent_sources(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory:
            root = Path(directory)
            host = root / "app/godot/android/build/src/main/java/com/godot/game/GodotApp.java"
            helper = root / "android/host/GodotLaunchIntentGuard.java"
            host.parent.mkdir(parents=True); helper.parent.mkdir(parents=True)
            host.write_text(TEMPLATE); helper.write_bytes((ROOT / "android/host/GodotLaunchIntentGuard.java").read_bytes())
            self.assertTrue(MODULE.prepare(root)); self.assertFalse(MODULE.prepare(root))
            host.write_text(TEMPLATE)
            self.assertTrue(MODULE.prepare(root))
            self.assertEqual(host.with_name(helper.name).read_bytes(), helper.read_bytes())

    def test_missing_inputs_do_not_leave_a_partial_host_patch(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory:
            root = Path(directory)
            host = root / "app/godot/android/build/src/main/java/com/godot/game/GodotApp.java"
            host.parent.mkdir(parents=True); host.write_text(TEMPLATE)
            with self.assertRaises(FileNotFoundError): MODULE.prepare(root)
            self.assertEqual(host.read_text(), TEMPLATE)


if __name__ == "__main__":
    unittest.main()
