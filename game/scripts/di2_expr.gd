class_name DI2Expr
extends RefCounted
## DI2 knowledge-base expressions (anim set group conditions, DT_ExpressionAliases_* rows, context conditions,
## CT_HitReact_* trees).
## Grammar: || or && and ! comparisons (== != >= <= > <), + - * / arithmetic, parentheses, "strings" and
## 'strings', numbers, #Alias (a DT_ExpressionAliases row, else a plain fact), {Scope}.Var (Self / Target / Hit /
## Victim / Attacker ... -> facts["Scope.Var"]), bare identifiers (facts), hasfact("", "Name"), rnd(a, b) (uniform
## random in [a, b]), floatbranch(cond, a, b) (a if cond else b), max(a, b) and min(a, b).
## Names are FNames, which are case-insensitive in DI2: a fact or alias missing under its exact spelling is looked
## up lower-cased (callers may store lower-case keys), and string comparisons ignore case.
## Facts are the primitive values the game computes; aliases come from data/expression_aliases.json.
## Each expression string is parsed once into a small tree (cached) and evaluated with short-circuit || and &&
## (results identical to evaluating every operand: the result of a chain is a bool either way).

static var aliases := {}
static var _aliases_lc := {}
static var _cache := {}             # expression string -> compiled node (null = empty expression, always true)

enum { OR, AND, NOT, CMP, ADD, SUB, MUL, DIV, NEG, CONST, ALIAS, FACT, CALL }


static func _ensure_aliases() -> void:
	if aliases.is_empty() and FileAccess.file_exists("res://data/expression_aliases.json"):
		aliases = Util.load_json("res://data/expression_aliases.json")
		for k: String in aliases:
			_aliases_lc[k.to_lower()] = aliases[k]


## A fact by FName: exact spelling first, then lower-case.
static func fact(f: Dictionary, key: String) -> Variant:
	if f.has(key):
		return f[key]
	return f.get(key.to_lower(), false)


static func _has_fact(f: Dictionary, key: String) -> bool:
	return f.has(key) or f.has(key.to_lower())


static func eval(expr: String, facts: Dictionary) -> bool:
	return truthy(value(expr, facts))


static func value(expr: String, facts: Dictionary, depth := 0) -> Variant:
	var n = _compiled(expr)
	if n == null:
		return true
	return _ev(n, facts, depth)


static func _compiled(expr: String) -> Variant:
	if _cache.has(expr):
		return _cache[expr]
	_ensure_aliases()
	var e := expr.strip_edges()
	var n = null
	if e != "":
		var st := {"t": tokens(e), "i": 0}
		n = _or(st)
	_cache[expr] = n
	return n


static func tokens(s: String) -> Array:
	var out := []
	var i := 0
	while i < s.length():
		var c := s[i]
		if c == " " or c == "\t" or c == "\n":
			i += 1
		elif s.substr(i, 2) in ["&&", "||", "==", "!=", ">=", "<="]:
			out.append(s.substr(i, 2))
			i += 2
		elif c in ["(", ")", "!", ">", "<", "+", "-", "*", "/", ","]:
			out.append(c)
			i += 1
		elif c == "\"" or c == "'":
			var j := s.find(c, i + 1)
			if j < 0:
				j = s.length()
			out.append({"str": s.substr(i + 1, j - i - 1)})
			i = j + 1
		else:
			var j := i
			while j < s.length() and not (s[j] in [" ", "\t", "\n", "(", ")", "!", ">", "<", "=", "&", "|", "\"", "'", "+", "-", "*", "/", ","]):
				j += 1
			var word := s.substr(i, j - i)
			if word == "and":
				out.append("&&")
			elif word == "or":
				out.append("||")
			else:
				out.append({"id": word})
			i = j
	return out


# --- parser: tokens -> nodes [kind, ...] -------------------------------------------------------------------------

static func _peek(st: Dictionary) -> Variant:
	return st["t"][st["i"]] if st["i"] < st["t"].size() else null


static func _is(st: Dictionary, op: String) -> bool:
	var t: Variant = _peek(st)
	return t is String and t == op


static func _or(st: Dictionary) -> Array:
	var v := _and(st)
	if not _is(st, "||"):
		return v
	var n := [OR, v]
	while _is(st, "||"):
		st["i"] += 1
		n.append(_and(st))
	return n


static func _and(st: Dictionary) -> Array:
	var v := _not(st)
	if not _is(st, "&&"):
		return v
	var n := [AND, v]
	while _is(st, "&&"):
		st["i"] += 1
		n.append(_not(st))
	return n


static func _not(st: Dictionary) -> Array:
	if _is(st, "!"):
		st["i"] += 1
		return [NOT, _not(st)]
	return _cmp(st)


static func _cmp(st: Dictionary) -> Array:
	var a := _sum(st)
	var t: Variant = _peek(st)
	if t is String and t in ["==", "!=", ">=", "<=", ">", "<"]:
		st["i"] += 1
		return [CMP, t, a, _sum(st)]
	return a


static func _sum(st: Dictionary) -> Array:
	var v := _prod(st)
	while _is(st, "+") or _is(st, "-"):
		var op: String = st["t"][st["i"]]
		st["i"] += 1
		v = [ADD if op == "+" else SUB, v, _prod(st)]
	return v


static func _prod(st: Dictionary) -> Array:
	var v := _atom(st)
	while _is(st, "*") or _is(st, "/"):
		var op: String = st["t"][st["i"]]
		st["i"] += 1
		v = [MUL if op == "*" else DIV, v, _atom(st)]
	return v


static func _atom(st: Dictionary) -> Array:
	var tok: Variant = _peek(st)
	if tok == null:
		return [CONST, false]
	st["i"] += 1
	if tok is String:
		if tok == "(":
			var v := _or(st)
			if _is(st, ")"):
				st["i"] += 1
			return v
		if tok == "-":
			return [NEG, _atom(st)]
		return [CONST, false]
	if tok.has("str"):
		return [CONST, tok["str"]]
	var name: String = tok["id"]
	if name.is_valid_float():
		return [CONST, float(name)]
	if _is(st, "("):
		# Function call: hasfact("", "Name"), rnd, floatbranch, max, min.
		st["i"] += 1
		var args := []
		while not _is(st, ")") and _peek(st) != null:
			if _is(st, ","):
				st["i"] += 1
				continue
			args.append(_or(st))
		st["i"] += 1
		return [CALL, name.to_lower(), args]
	if name.begins_with("#"):
		var key := name.substr(1)
		return [ALIAS, key, key.to_lower()]
	if name.begins_with("{"):
		return [FACT, name.replace("{", "").replace("}", "")]
	match name:
		"true", "True": return [CONST, true]
		"false", "False": return [CONST, false]
	return [FACT, name]


# --- evaluation -----------------------------------------------------------------------------------------------

static func _ev(n: Array, f: Dictionary, d: int) -> Variant:
	match n[0]:
		FACT:
			return fact(f, n[1])
		CONST:
			return n[1]
		AND:
			for i in range(1, n.size()):
				if not truthy(_ev(n[i], f, d)):
					return false
			return true
		OR:
			for i in range(1, n.size()):
				if truthy(_ev(n[i], f, d)):
					return true
			return false
		NOT:
			return not truthy(_ev(n[1], f, d))
		CMP:
			var a: Variant = _ev(n[2], f, d)
			var b: Variant = _ev(n[3], f, d)
			var strs := a is String or b is String
			match n[1]:
				"==": return str(a).nocasecmp_to(str(b)) == 0 if strs else num(a) == num(b)
				"!=": return str(a).nocasecmp_to(str(b)) != 0 if strs else num(a) != num(b)
				">=": return num(a) >= num(b)
				"<=": return num(a) <= num(b)
				">": return num(a) > num(b)
				"<": return num(a) < num(b)
			return a
		ALIAS:
			var key: String = n[1]
			if _has_fact(f, key):
				return fact(f, key)
			if d < 24:
				if aliases.has(key):
					return value(aliases[key], f, d + 1)
				if _aliases_lc.has(n[2]):
					return value(_aliases_lc[n[2]], f, d + 1)
			return false
		ADD:
			return num(_ev(n[1], f, d)) + num(_ev(n[2], f, d))
		SUB:
			return num(_ev(n[1], f, d)) - num(_ev(n[2], f, d))
		MUL:
			return num(_ev(n[1], f, d)) * num(_ev(n[2], f, d))
		DIV:
			var x := num(_ev(n[1], f, d))
			var y := num(_ev(n[2], f, d))
			return x / y if y != 0.0 else 0.0
		NEG:
			return -num(_ev(n[1], f, d))
		CALL:
			var args: Array = n[2]
			match n[1]:
				"hasfact":
					return _has_fact(f, str(_ev(args.back(), f, d))) if not args.is_empty() else false
				"rnd":
					return randf_range(num(_ev(args[0], f, d)), num(_ev(args[1], f, d))) if args.size() >= 2 else randf()
				"floatbranch":
					if args.size() < 3:
						return 0.0
					return _ev(args[1], f, d) if truthy(_ev(args[0], f, d)) else _ev(args[2], f, d)
				"max":
					return maxf(num(_ev(args[0], f, d)), num(_ev(args[1], f, d))) if args.size() >= 2 else 0.0
				"min":
					return minf(num(_ev(args[0], f, d)), num(_ev(args[1], f, d))) if args.size() >= 2 else 0.0
			return false
	return false


static func num(v: Variant) -> float:
	if v is bool:
		return 1.0 if v else 0.0
	if v is float or v is int:
		return float(v)
	if v is String and v.is_valid_float():
		return float(v)
	return 0.0


static func truthy(v: Variant) -> bool:
	if v is bool:
		return v
	if v is float or v is int:
		return v != 0
	if v is String:
		return v != ""
	return v != null
