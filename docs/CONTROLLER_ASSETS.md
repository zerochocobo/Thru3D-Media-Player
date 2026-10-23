# Controller visual assets

OpenXR runtime geometry takes priority. The source includes PICO profile selection, pose/input binding and animated fallback logic, plus the MIT notice and manifest at `app/godot/models/controllers/pico`. The six fallback GLBs are excluded from public Git alongside other separately prepared models.

Obtain the unmodified files from WebXR Input Profiles revision `f4992299601614adbfefd398dc8e281556bb7444`, `packages/assets/profiles/{pico-neo3,pico-4,pico-4u}/{left,right}.glb`. Use the exact byte sizes/SHA-256 in the manifest:

```powershell
python tools/Prepare-ControllerModels.py --source <pinned-upstream-checkout>
godot --headless --editor --import --xr-mode off --path app/godot
```

The helper also accepts a folder with all six files renamed as in the manifest. It validates every input before writing. Import preserves source dimensions/grip origin; runtime code animates existing min/max/value nodes without replacing tracking. The retained notices apply to redistribution. Missing runtime geometry, imported fallbacks, interaction profiles and hand-tracking support are separate capabilities; no universal PICO hand-tracking or lowest-device performance claim is made.

公开Git保留PICO模型选择／动画源码、MIT声明及哈希清单，六份GLB另行准备。辅助脚本先验证全部输入再复制，之后执行Godot导入；不包含从头显提取的资产、私有SDK或设备数据。
