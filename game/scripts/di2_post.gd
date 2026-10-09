extends CompositorEffect
## DI2's eye adaptation and tone mapping for the DI2 test map (DI2Map, main.gd --map=<name>), as a Godot compositor
## effect on the HDR colour buffer after transparents. Godot's own tonemap is set to linear (white 1, exposure 1) by
## DI2Map, so the display value is DI2's. Data: map.json environment.post (tools/build_test_map.py, tools/test_map/post.py);
## RE notes: recon/TEST_MAP.md "Exposure and tone mapping".
##   1. LUT (once): DI2's FLUTBlenderPS p1 (Global 2460) translated to GLSL (tools/re_exposure/hlsl2glsl.py, written
##      into the map folder at build time) renders the 32^3 LUT with DI2's constants (post.lut_cb0) and the level's
##      grading LUT texture. Its eye-adaptation inputs (texels 0 and 3: HDR / SDR exposure) are equal here (ratio 1:
##      the scene buffer below is exposed with the SDR exposure directly).
##   2. Histogram: di2_post_histogram.glsl (DI2's FHistogramCS), read back asynchronously.
##   3. Eye adaptation on the CPU: DI2's FEyeAdaptationPS (Global 1553), see _adapt().
##   4. Tonemap: di2_post_tonemap.glsl (DI2's FTonemapPS / VS) with the smoothed exposure.
## The level's lights and sky are pre-exposed by `pre_exposure` (DI2's PreExposure: scene buffer = luminance * P), so
## the histogram and tonemap divide by it (View.OneOverPreExposure).

var post: Dictionary = {}
var pre_exposure := 1.0
var map_dir := ""
## UE exponential height fog (environment.fog, tools/test_map/post.py height_fog) and the colour it fades to: the sky
## cubemap's non-directional (lowest-mip) colour * InscatteringTextureTint, pre-exposed (set by DI2Map).
var fog: Dictionary = {}
var fog_inscatter := Color(0, 0, 0)

## Current DI2 exposure (View.CurrentEyeAdaption .x smoothed, .y target) and average luminance (.z), for DI2Map's
## hooks (particle emissive compensation). 0 until the first histogram arrives.
var exposure := 0.0
var target_exposure := 0.0
var average_luminance := 0.0

var _rd: RenderingDevice
var _ok := false
var _hist_shader: RID
var _hist_pipe: RID
var _tm_shader: RID
var _tm_pipe: RID
var _fog_shader: RID
var _fog_pipe: RID
var _fog_ubo: RID
var _depth_sampler: RID
var _hist_buf: RID
var _lut: RID
var _lut_sampler: RID
var _pending := false
var _hist := PackedInt32Array()
var _last_us := 0
var _owned: Array[RID] = []
var _pipes: Array[RID] = []


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		# reverse creation order; pipelines go with their shaders
		for i in range(_owned.size() - 1, -1, -1):
			var r := _owned[i]
			if r.is_valid() and r not in _pipes:
				_rd.free_rid(r)


func _compile(path: String) -> RID:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("DI2Post: cannot read %s" % path)
		return RID()
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = text.replace("#[compute]", "")
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("DI2Post: %s: %s" % [path, spirv.compile_error_compute.left(2000)])
		return RID()
	var sh := _rd.shader_create_from_spirv(spirv)
	_owned.append(sh)
	return sh


func _setup() -> void:
	_rd = RenderingServer.get_rendering_device()
	if not _rd:
		return
	_hist_shader = _compile("res://shaders/di2_post_histogram.glsl")
	_tm_shader = _compile("res://shaders/di2_post_tonemap.glsl")
	if not _hist_shader.is_valid() or not _tm_shader.is_valid():
		return
	_hist_pipe = _rd.compute_pipeline_create(_hist_shader)
	_tm_pipe = _rd.compute_pipeline_create(_tm_shader)
	_pipes.append_array([_hist_pipe, _tm_pipe])
	if not fog.is_empty():
		_fog_shader = _compile("res://shaders/di2_post_fog.glsl")
		if _fog_shader.is_valid():
			_fog_pipe = _rd.compute_pipeline_create(_fog_shader)
			_pipes.append(_fog_pipe)
			var z := PackedByteArray()
			z.resize(176)
			_fog_ubo = _rd.uniform_buffer_create(176, z)
			_owned.append(_fog_ubo)
			var ds := RDSamplerState.new()
			_depth_sampler = _rd.sampler_create(ds)
			_owned.append(_depth_sampler)
	var zero := PackedByteArray()
	zero.resize(256)
	_hist_buf = _rd.storage_buffer_create(256, zero)
	_owned.append(_hist_buf)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_lut_sampler = _rd.sampler_create(ss)
	_owned.append(_lut_sampler)
	_ok = _build_lut()


## 1. DI2's LUT: one compute dispatch of the translated FLUTBlenderPS over 32 x 32 x 32 texels.
func _build_lut() -> bool:
	var sh := _compile(map_dir + "/" + String(post.get("lut_shader", "post_lut.glsl")))
	if not sh.is_valid():
		return false
	var pipe := _rd.compute_pipeline_create(sh)
	_pipes.append(pipe)
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = 32
	fmt.height = 32
	fmt.depth = 32
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_lut = _rd.texture_create(fmt, RDTextureView.new())
	_owned.append(_lut)
	var cb0 := PackedInt32Array(post["lut_cb0"]).to_byte_array()
	var cb1 := PackedFloat32Array()
	cb1.resize(240 * 4)
	# View.OverallLUTGradingIntensity (cb1[239].x, a DI2 view member): 1 (runtime writer not traced, UNVERIFIED #57).
	cb1[239 * 4] = 1.0
	var ea := PackedFloat32Array([1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0])
	var u0 := _rd.uniform_buffer_create(cb0.size(), cb0)
	var u1 := _rd.uniform_buffer_create(cb1.size() * 4, cb1.to_byte_array())
	var u4 := _rd.uniform_buffer_create(ea.size() * 4, ea.to_byte_array())
	var grade := _grading_texture()
	var uniforms: Array[RDUniform] = [_ub(0, u0), _ub(1, u1), _tex(2, grade), _img(3, _lut), _ub(4, u4)]
	var us := _rd.uniform_set_create(uniforms, sh, 0)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, pipe)
	_rd.compute_list_bind_uniform_set(cl, us, 0)
	_rd.compute_list_dispatch(cl, 4, 4, 32)
	_rd.compute_list_end()
	for r in [us, u0, u1, u4, grade]:
		_rd.free_rid(r)
	return true


## The level's ColorGradingLUT (e.g. T_VeniceDay_LUT, 256 x 16 unwrapped 16^3) as an RD texture, raw (the LUT shader
## samples it in PQ space; the asset's sRGB flag picks the format).
func _grading_texture() -> RID:
	var img := Image.new()
	var bytes := FileAccess.get_file_as_bytes(map_dir + "/" + String(post.get("lut_file", "")))
	var fmt := RDTextureFormat.new()
	if bytes.is_empty() or img.load_dds_from_buffer(bytes) != OK:
		push_warning("DI2Post: no grading LUT texture; neutral weight only")
		img = Image.create_empty(256, 16, false, Image.FORMAT_RGBA8)
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	fmt.width = img.get_width()
	fmt.height = img.get_height()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB if post.get("lut_srgb", false) \
		else RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return _rd.texture_create(fmt, RDTextureView.new(), [img.get_data()])


func _ub(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func _img(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _tex(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_lut_sampler)
	u.add_id(rid)
	return u


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not _rd:
		_setup()
	if not _ok:
		return
	var sb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not sb:
		return
	var size := sb.get_internal_size()
	if size.x < 2 or size.y < 2:
		return
	var now := Time.get_ticks_usec()
	var dt := 0.0 if _last_us == 0 else (now - _last_us) / 1e6
	_last_us = now
	_adapt(dt)
	var ea: Dictionary = post["eye_adaptation"]
	for view in sb.get_view_count():
		var color := sb.get_color_layer(view)
		if _fog_pipe.is_valid():
			_fog(render_data, sb, view, color, size)
		# 2. histogram of this frame (read back for the next frames' adaptation)
		if not _pending:
			_rd.buffer_clear(_hist_buf, 0, 256)
			var hp := PackedFloat32Array([size.x, size.y, 1.0 / pre_exposure, ea["luminance_min"], ea["histogram_scale"],
				ea["histogram_bias"], ea["black_bucket_influence"], 0.0]).to_byte_array()
			var hu: Array[RDUniform] = [_img(0, color), _sb(1, _hist_buf)]
			var hs := UniformSetCacheRD.get_cache(_hist_shader, 0, hu)
			var cl := _rd.compute_list_begin()
			_rd.compute_list_bind_compute_pipeline(cl, _hist_pipe)
			_rd.compute_list_bind_uniform_set(cl, hs, 0)
			_rd.compute_list_set_push_constant(cl, hp, hp.size())
			_rd.compute_list_dispatch(cl, (size.x / 2 + 7) / 8, (size.y / 2 + 7) / 8, 1)
			_rd.compute_list_end()
			_pending = true
			_rd.buffer_get_data_async(_hist_buf, _on_histogram)
		# 4. tonemap with the current exposure
		if exposure <= 0.0:
			continue
		var tp := PackedFloat32Array([size.x, size.y, exposure / pre_exposure, post.get("vignette_intensity", 0.0),
			post.get("editor_nit_level", 160.0), 0.0, 0.0, 0.0]).to_byte_array()
		var tu: Array[RDUniform] = [_img(0, color), _tex(1, _lut)]
		var ts := UniformSetCacheRD.get_cache(_tm_shader, 0, tu)
		var cl2 := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl2, _tm_pipe)
		_rd.compute_list_bind_uniform_set(cl2, ts, 0)
		_rd.compute_list_set_push_constant(cl2, tp, tp.size())
		_rd.compute_list_dispatch(cl2, (size.x + 7) / 8, (size.y + 7) / 8, 1)
		_rd.compute_list_end()


## UE height fog pass (di2_post_fog.glsl). Godot's scene depth is reversed-Z in [0, 1]: OpenGL-style clip z = 1 - 2d.
func _fog(render_data: RenderData, sb: RenderSceneBuffersRD, view: int, color: RID, size: Vector2i) -> void:
	var sd := render_data.get_render_scene_data()
	var ip := sd.get_view_projection(view).inverse()
	var cam := sd.get_cam_transform()
	var l: Array = fog["layers"]
	var f := PackedFloat32Array()
	for c in [ip.x, ip.y, ip.z, ip.w]:
		f.append_array([c.x, c.y, c.z, c.w])
	f.append_array([cam.origin.x, cam.origin.y, cam.origin.z, float(fog.get("start_distance", 0.0))])
	for i in 2:
		f.append_array([float(l[i][0]), float(l[i][1]), float(l[i][2]), 0.0])
	f.append_array([fog_inscatter.r, fog_inscatter.g, fog_inscatter.b, 1.0 - float(fog.get("max_opacity", 1.0))])
	f.append_array([cam.basis.x.y, cam.basis.y.y, cam.basis.z.y, 0.0])
	f.append_array([size.x, size.y, 0.0, 0.0])
	_rd.buffer_update(_fog_ubo, 0, f.size() * 4, f.to_byte_array())
	var du := RDUniform.new()
	du.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	du.binding = 1
	du.add_id(_depth_sampler)
	du.add_id(sb.get_depth_layer(view))
	var fu: Array[RDUniform] = [_img(0, color), du, _ub(2, _fog_ubo)]
	var us := UniformSetCacheRD.get_cache(_fog_shader, 0, fu)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _fog_pipe)
	_rd.compute_list_bind_uniform_set(cl, us, 0)
	_rd.compute_list_dispatch(cl, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	_rd.compute_list_end()


func _sb(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func _on_histogram(data: PackedByteArray) -> void:
	_hist = data.to_int32_array()
	_pending = false


## 3. DI2's FEyeAdaptationPS (Global 1553, extracted/shaders/lighting/Global_001553_EyeAdaptPS.hlsl), SDR texel:
##   Lhist = exp2 of the histogram's mean log2 luminance between ExposureLowPercent and ExposureHighPercent of the
##           weight (bin i at log2 L = (i / 63 - HistogramBias) / HistogramScale);
##   grey  = 0.18 + 0.8 (1 - DesaturationAmount) (albedoMean - 0.18): DI2's scene-albedo texture (t8) is not available
##           in Godot's forward renderer -> grey = 0.18 (UNVERIFIED #57);
##   L     = Lhist / grey;  derived = (volumetric lightmap ambient at the camera, else L) * DerivedMaxBrightnessScale
##           (no lightmaps here -> L);
##   target = min(max(Min, L), ClampInfluence > 0.5 ? clamp(derived, Min, Max) : Max), Min / Max =
##           MinAverageLuminance / 0.18, MaxAverageLuminance / 0.18 (EV100 -> 1.2 * 2^EV);
##   smoothing in log2 space from old = Comp / previous exposure: linear at Speed EV/s when |delta| >
##           ExponentialTransitionDistance, else delta * (1 - 2^(-dt * Speed)) * M; exposure = Comp / smoothed,
##           Comp = 2^AutoExposureBias * 2^curve(log2(Lhist_prev / 1.2)).
func _adapt(dt: float) -> void:
	if _hist.size() < 64:
		return
	var ea: Dictionary = post["eye_adaptation"]
	var total := 0.0
	for i in 64:
		total += _hist[i]
	if total <= 0.0:
		return
	var low_rem := total * float(ea["low_percent"])
	var win := total * float(ea["high_percent"])
	var acc := 0.0
	var wsum := 0.0
	for i in 64:
		var v := float(_hist[i])
		var sub := minf(v, low_rem)
		low_rem -= sub
		win -= sub
		v -= sub
		var take := minf(v, win)
		win -= take
		acc += take * ((i / 63.0 - float(ea["histogram_bias"])) / float(ea["histogram_scale"]))
		wsum += take
	var lhist := pow(2.0, acc / maxf(1e-4, wsum))
	var curve_ev := log(maxf(average_luminance if average_luminance > 0.0 else lhist, 1e-10) / float(ea["luminance_max_factor"])) / log(2.0)
	var comp := pow(2.0, float(ea["bias"])) * pow(2.0, _curve(ea.get("bias_curve"), curve_ev))
	average_luminance = lhist
	var grey := 0.18
	var lmin := float(ea["min_luminance"]) / 0.18
	var lmax := float(ea["max_luminance"]) / 0.18
	var l := lhist / grey
	var derived := clampf(l * float(ea.get("derived_max_scale", 1.0)), lmin, lmax)
	var influence = ea.get("derived_clamp_influence")
	var target := minf(maxf(lmin, l), derived if influence != null and float(influence) > 0.5 else lmax)
	target_exposure = comp / maxf(1e-4, target)
	if exposure <= 0.0:
		# First histogram: start settled (DI2 starts from its eye-adaptation texture's previous value).
		exposure = target_exposure
		print("DI2Post: first histogram Lhist %s cd/m2, target EV100 %.2f, exposure %s, comp %.3f" % [lhist,
			log(target * 0.18 / 1.2) / log(2.0), target_exposure, comp])
		return
	var old := comp / exposure
	var lt := log(target) / log(2.0)
	var lo := log(old) / log(2.0)
	var d := lt - lo
	var up := d > 0.0
	var speed := float(ea["speed_up"] if up else ea["speed_down"])
	var dist := float(ea["transition_distance"])
	# ExponentialUp/DownM: CPU-side values not traced; M = 1 / (dist * ln 2) makes the exponential's rate equal the
	# linear speed at the transition distance (UNVERIFIED #57).
	var m := 1.0 / (dist * log(2.0))
	var s: float
	if absf(d) > dist:
		s = minf(lo + dt * speed, lt) if lo < lt else maxf(lo - dt * speed, lt)
	else:
		s = lo + d * (1.0 - pow(2.0, -dt * speed)) * m
	exposure = comp / maxf(1e-4, pow(2.0, s))


## FRichCurve::Eval for the exposure-compensation curve (keys [time, value, interp, arrive, leave]; constant
## extrapolation; cubic = Bezier with the keys' tangents * segment / 3).
func _curve(c, t: float) -> float:
	if c == null or (c["keys"] as Array).is_empty():
		return 0.0
	var k: Array = c["keys"]
	if t <= float(k[0][0]):
		return float(k[0][1])
	if t >= float(k[-1][0]):
		return float(k[-1][1])
	for i in k.size() - 1:
		var a: Array = k[i]
		var b: Array = k[i + 1]
		if t < float(b[0]):
			var span := float(b[0]) - float(a[0])
			var x := (t - float(a[0])) / span
			match String(a[2]):
				"RCIM_Constant":
					return float(a[1])
				"RCIM_Linear":
					return lerpf(float(a[1]), float(b[1]), x)
				_:
					var p0 := float(a[1])
					var p3 := float(b[1])
					var p1 := p0 + float(a[4]) * span / 3.0
					var p2 := p3 - float(b[3]) * span / 3.0
					var u := 1.0 - x
					return u * u * u * p0 + 3.0 * u * u * x * p1 + 3.0 * u * x * x * p2 + x * x * x * p3
	return float(k[-1][1])
