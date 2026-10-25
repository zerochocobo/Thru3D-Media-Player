# Comic reading and translation (Beta)

Enable comic speech or translation for the current reading batch; reopening starts disabled. Global language/voice/volume/appearance preferences persist. Eligible OCR dialogue is spoken after ray dwell with existing preset or caller-owned custom voices. Menus, page/source/voice changes and stale generations cancel work. Text, translations and speech use bounded runtime caches rather than a new content disk archive.

OCR has conservative Chinese/Japanese/English source paths; uncertain content, handwriting and some layouts may be skipped or misread. More target languages do not expand OCR coverage. Neighbor-page preparation follows memory budgets, without neighboring photo-3D caching. Supported flat/generated-stereo photos retain overlays across 2D/3D changes; native stereo, panoramas, portrait layouts and spatial scenes have separate exclusions.

Translation sends selected recognized dialogue text and language choices to Bing, with Edge fallback and anonymous runtime sessions. This text path does not upload page images. No developer API key is embedded; cookies/tokens are obtained at runtime. Provider behavior, connectivity and rate limits can change. Anonymous access is not a service guarantee or commercial-usage license. Public verification uses fake responses, not user pages or live translation requests.

Targets match the existing 19 narration languages, with separate Simplified/Traditional Chinese choices. White with dark text is the default; dark appearance and text size are remembered. Non-reading ray hover temporarily reveals original text. Translated dialogue can use the current speech language/voice path; neither OCR nor translation is guaranteed accurate.

## Separate OCR payloads

`third_party/comic-ocr/model.json` pins two PP-OCRv6 Small ONNX files from RapidAI/RapidOCR v3.10.0:

- Detector: https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/det/PP-OCRv6_det_small.onnx
- Recognizer: https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx

Supply matching files under ignored `models/comic-ocr/v6-small/`, with manifest filenames, byte lengths and SHA-256. Normal Gradle staging and `Assert-NarrationPackaged.ps1` stop for missing/corrupt payloads. These are additional to narration/reference/VAD bundles. Native inference reuses ONNX Runtime without Python/OpenCV.

Only source, metadata and instructions are published: no OCR weights, original pages, transcripts, recordings, voice codes or device captures. Project GPL permissions do not grant rights to excluded models/pages/voices; consult their original redistribution notices. The protocol reference is plainheart/bing-translate-api revision f37b17b8bc7848b3be38f4440bec5285ad1fd3e2, with its original MIT notice in `third_party/bing-translate-api/LICENSE.txt`.

漫画朗读／翻译仍为测试版，开关按本次阅读生效。OCR本地处理，在线翻译发送所选识别对白；19种目标语言不等于19种源OCR已验证。权重、原页面、个人声音及研发资料不公开。
