// acl13dec: decode an ACL 1.3 CompressedClip (as stored by DI2's UE4 ACL plugin) into raw samples.
//
//   acl13dec <in.acl> <out.bin>
//
// out.bin layout (little endian):
//   u32 num_bones, u32 num_samples, f32 sample_rate, u32 has_scale
//   then num_samples * num_bones * 10 floats: rot xyzw, trans xyz, scale xyz
// Bone order is the ACL track order (UE: CompressedTrackToSkeletonMapTable order).
#include <acl/core/compressed_clip.h>
#include <acl/algorithm/uniformly_sampled/decoder.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace acl;

struct Writer : OutputWriter
{
	float* out;
	void write_bone_rotation(uint16_t i, const Quat_32& q)
	{
		float* o = out + i * 10;
		o[0] = quat_get_x(q); o[1] = quat_get_y(q); o[2] = quat_get_z(q); o[3] = quat_get_w(q);
	}
	void write_bone_translation(uint16_t i, const Vector4_32& v)
	{
		float* o = out + i * 10 + 4;
		o[0] = vector_get_x(v); o[1] = vector_get_y(v); o[2] = vector_get_z(v);
	}
	void write_bone_scale(uint16_t i, const Vector4_32& v)
	{
		float* o = out + i * 10 + 7;
		o[0] = vector_get_x(v); o[1] = vector_get_y(v); o[2] = vector_get_z(v);
	}
};

int main(int argc, char** argv)
{
	if (argc != 3) { std::fprintf(stderr, "usage: acl13dec <in.acl> <out.bin>\n"); return 2; }
	FILE* f = std::fopen(argv[1], "rb");
	if (!f) { std::perror(argv[1]); return 1; }
	std::fseek(f, 0, SEEK_END);
	long size = std::ftell(f);
	std::fseek(f, 0, SEEK_SET);
	// ACL requires 16-byte alignment of the clip buffer.
	void* buf = _aligned_malloc(size, 16);
	std::fread(buf, 1, size, f);
	std::fclose(f);

	const CompressedClip* clip = reinterpret_cast<const CompressedClip*>(buf);
	ErrorResult err = clip->is_valid(false);
	if (err.any()) { std::fprintf(stderr, "invalid clip: %s\n", err.c_str()); return 1; }

	const ClipHeader& header = get_clip_header(*clip);
	uniformly_sampled::DecompressionContext<uniformly_sampled::DefaultDecompressionSettings> ctx;
	ctx.initialize(*clip);

	const uint32_t num_bones = header.num_bones;
	const uint32_t num_samples = header.num_samples;
	std::vector<float> frame(num_bones * 10);
	FILE* o = std::fopen(argv[2], "wb");
	if (!o) { std::perror(argv[2]); return 1; }
	uint32_t has_scale = header.has_scale;
	std::fwrite(&num_bones, 4, 1, o);
	std::fwrite(&num_samples, 4, 1, o);
	std::fwrite(&header.sample_rate, 4, 1, o);
	std::fwrite(&has_scale, 4, 1, o);
	for (uint32_t s = 0; s < num_samples; ++s)
	{
		for (uint32_t b = 0; b < num_bones; ++b)
		{
			float* p = &frame[b * 10];
			p[0] = p[1] = p[2] = 0.0f; p[3] = 1.0f;
			p[4] = p[5] = p[6] = 0.0f;
			p[7] = p[8] = p[9] = header.default_scale ? 1.0f : 0.0f;
		}
		Writer w;
		w.out = frame.data();
		ctx.seek(float(s) / header.sample_rate, SampleRoundingPolicy::Nearest);
		ctx.decompress_pose(w);
		std::fwrite(frame.data(), sizeof(float), frame.size(), o);
	}
	std::fclose(o);
	std::printf("%u bones, %u samples @ %.2f Hz, scale=%u\n", num_bones, num_samples, header.sample_rate, has_scale);
	_aligned_free(buf);
	return 0;
}
