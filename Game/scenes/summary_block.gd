extends RefCounted
## 摘要里的四个只读房间块（`units`、`organizations`、`funds`、`public_works`）
## 与权威 `state` 视图同形：每块要么整块存在，要么是与空房间相同的空数组形状。
## 这里只负责把一块读成行数组，不判断角色、权限或数据新鲜度。


## 从成员摘要里取出 `key` 块中 `array_key` 的行。摘要缺失、不是字典、缺块、
## 块不是字典、数组缺失或不是数组时都返回空数组：空块与“摘要没带这块”在当前
## 规则下形状相同，按设计不区分。调用方应把空数组当作“没有可用的初始视图”，
## 退回自己上次已知的视图，而不是当成权威说房间为空。
##
## 返回深拷贝，行顺序保持摘要里的原有顺序。
static func summary_block(summary: Variant, key: String, array_key: String) -> Array:
	if not summary is Dictionary:
		return []
	var block: Variant = (summary as Dictionary).get(key)
	if not block is Dictionary:
		return []
	var rows: Variant = (block as Dictionary).get(array_key)
	if not rows is Array:
		return []
	var result: Array = []
	for value: Variant in rows:
		if value is Dictionary:
			result.append((value as Dictionary).duplicate(true))
	return result
