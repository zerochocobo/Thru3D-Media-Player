extends RefCounted
const Tasks := preload("res://scripts/subtitle_tasks.gd")
const I18n := preload("res://scripts/i18n.gd")
static func rows(report: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append({"title": I18n.t("Resume all" if report.get("paused", false) else "Pause all"), "icon": "play" if report.get("paused", false) else "pause",
		"setting": ["subtitle_task_command", {"operation": "resume_all" if report.get("paused", false) else "pause_all"}]})
	for job: Dictionary in report.get("jobs", []):
		# Direct icon buttons, most frequent action rightmost; names are hover tips.
		var actions := []
		if job.state not in ["complete", "cancelled"]:
			actions.append({"operation": "first", "icon": "arrow_up", "tip": "Move to front"})
			actions.append({"operation": "cancel", "icon": "close", "tip": "Cancel"})
			if job.state == "error": actions.append({"operation": "retry", "icon": "refresh", "tip": "Retry"})
			elif job.state == "paused": actions.append({"operation": "resume", "icon": "play", "tip": "Resume"})
			else: actions.append({"operation": "pause", "icon": "pause", "tip": "Pause"})
		else:
			if job.state == "cancelled": actions.append({"operation": "resume", "icon": "play", "tip": "Resume"})
			actions.append({"operation": "remove", "icon": "trash", "tip": "Remove"})
		var progress := float(job.get("progress", 0)) / 100.0
		if job.state == "translating": progress = float(job.get("translated", 0)) / maxf(1, float(job.get("total", 0)))
		var detail := Tasks.caption(job)
		if float(job.get("speed", 0)) > 0 and job.state == "listening": detail += " · %.1f×" % float(job.speed)
		result.append({"title": str(job.title), "hint": detail, "info": str(job.title) + "\n" + str(job.language) + (" → " + str(job.target) if not str(job.target).is_empty() else "") + "\n" + I18n.t("Session only" if not job.get("persistent", false) else "Saved cache"),
			"task_id": str(job.id), "task_actions": actions, "task_progress": progress})
	if report.get("jobs", []).is_empty(): result.append({"title": I18n.t("No subtitle tasks"), "icon": "subtitle", "enabled": false})
	else: result.append({"title": I18n.t("Clear finished tasks"), "icon": "trash", "setting": ["subtitle_task_command", {"operation": "clear_done"}]})
	return result
