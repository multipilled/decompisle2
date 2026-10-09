shader_type spatial;
// Emitters whose DI2 material has no base pass for the emitter's vertex factory (e.g. PSMI_SmokeTrail on GPU sprites:
// its shader map holds only beam-trail / mesh / local shaders). UE 4.27 draws those with the engine default material;
// the port draws nothing (DI2ParticleMaterials.build, UNVERIFIED: recon/PARTICLES.md 4.3).
render_mode unshaded, cull_disabled, depth_draw_never;

void fragment() {
	discard;
}
