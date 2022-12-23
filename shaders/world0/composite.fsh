#version 400 compatibility

/*
--------------------------------------------------------------------------------

  Photon Shaders by SixthSurge

  world0/composite.fsh:
  Render volumetric fog

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

/* DRAWBUFFERS:56 */
layout (location = 0) out vec3 fog_scattering;
layout (location = 1) out vec3 fog_transimttance;

in vec2 uv;

flat in vec3 light_color;
flat in vec3 sky_color;
flat in mat2x3 air_fog_coeff[2];

uniform sampler2D noisetex;

uniform sampler2D colortex1; // Gbuffer data

uniform sampler2D depthtex1;

uniform sampler3D colortex3; // 3D worley noise

#ifdef SHADOW
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
#ifdef SHADOW_COLOR
uniform sampler2D shadowcolor0;
#endif
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;

uniform vec3 cameraPosition;

uniform float near;
uniform float far;

uniform float eyeAltitude;
uniform float blindness;

uniform int isEyeInWater;

uniform int frameCounter;

uniform float frameTimeCounter;

uniform vec3 light_dir;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;

uniform float eye_skylight;

#define WORLD_OVERWORLD

#include "/include/utility/encoding.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/space_conversion.glsl"

#include "/include/atmosphere.glsl"
#include "/include/phase_functions.glsl"
#include "/include/shadow_distortion.glsl"

const uint  air_fog_min_step_count    = 8;
const uint  air_fog_max_step_count    = 25;
const float air_fog_step_count_growth = 0.1;
const float air_fog_volume_top        = 320.0;
const float air_fog_volume_bottom     = SEA_LEVEL - 24.0;
const vec2  air_fog_falloff_start     = vec2(AIR_FOG_RAYLEIGH_FALLOFF_START, AIR_FOG_MIE_FALLOFF_START) + SEA_LEVEL;
const vec2  air_fog_falloff_half_life = vec2(AIR_FOG_RAYLEIGH_FALLOFF_HALF_LIFE, AIR_FOG_MIE_FALLOFF_HALF_LIFE);

vec2 air_fog_density(vec3 world_pos) {
	const vec2 mul = -rcp(air_fog_falloff_half_life);
	const vec2 add = -mul * air_fog_falloff_start;

	vec2 density = exp2(min(world_pos.y * mul + add, 0.0));

	// fade away below sea level
	density *= linear_step(air_fog_volume_bottom, SEA_LEVEL, world_pos.y);

#ifdef AIR_FOG_CLOUDY_NOISE
	const vec3 wind = 0.03 * vec3(1.0, 0.0, 0.7);

	float noise = texture(colortex3, 0.015 * world_pos + wind * frameTimeCounter).x;

	density.y *= 2.0 * sqr(1.0 - noise);
#endif

	return density;
}

mat2x3 raymarch_air_fog(vec3 world_start_pos, vec3 world_end_pos, bool sky, float skylight, float dither) {
	vec3 world_dir = world_end_pos - world_start_pos;

	float length_sq = length_squared(world_dir);
	float norm = inversesqrt(length_sq);
	float ray_length = length_sq * norm;
	world_dir *= norm;

	vec3 shadow_start_pos = transform(shadowModelView, world_start_pos - cameraPosition);
	     shadow_start_pos = project_ortho(shadowProjection, shadow_start_pos);

	vec3 shadow_dir = mat3(shadowModelView) * world_dir;
	     shadow_dir = diagonal(shadowProjection).xyz * shadow_dir;

	float distance_to_lower_plane = (air_fog_volume_bottom - eyeAltitude) / world_dir.y;
	float distance_to_upper_plane = (air_fog_volume_top    - eyeAltitude) / world_dir.y;
	float distance_to_volume_start, distance_to_volume_end;

	if (eyeAltitude < air_fog_volume_bottom) {
		// Below volume
		distance_to_volume_start = distance_to_lower_plane;
		distance_to_volume_end = world_dir.y < 0.0 ? -1.0 : distance_to_lower_plane;
	} else if (eyeAltitude < air_fog_volume_top) {
		// Inside volume
		distance_to_volume_start = 0.0;
		distance_to_volume_end = world_dir.y < 0.0 ? distance_to_lower_plane : distance_to_upper_plane;
	} else {
		// Above volume
		distance_to_volume_start = distance_to_upper_plane;
		distance_to_volume_end = world_dir.y < 0.0 ? distance_to_upper_plane : -1.0;
	}

	if (distance_to_volume_end < 0.0) return mat2x3(vec3(0.0), vec3(1.0));

	ray_length = sky ? distance_to_volume_end : ray_length;
	ray_length = clamp(ray_length - distance_to_volume_start, 0.0, far);

	uint step_count = uint(float(air_fog_min_step_count) + air_fog_step_count_growth * ray_length);
	     step_count = min(step_count, air_fog_max_step_count);

	float step_length = ray_length * rcp(float(step_count));

	vec3 world_step = world_dir * step_length;
	vec3 world_pos  = world_start_pos + world_dir * (distance_to_volume_start + step_length * dither);

	vec3 shadow_step = shadow_dir * step_length;
	vec3 shadow_pos  = shadow_start_pos + shadow_dir * (distance_to_volume_start + step_length * dither);

	vec3 transmittance = vec3(1.0);

	mat2x3 light_sun = mat2x3(0.0); // Rayleigh, mie
	mat2x3 light_sky = mat2x3(0.0); // Rayleigh, mie

	for (int i = 0; i < step_count; ++i, world_pos += world_step, shadow_pos += shadow_step) {
		vec3 shadow_screen_pos = distort_shadow_space(shadow_pos) * 0.5 + 0.5;

#ifdef SHADOW
	 	ivec2 shadow_texel = ivec2(shadow_screen_pos.xy * shadowMapResolution * MC_SHADOW_QUALITY);

	#ifdef AIR_FOG_COLORED_LIGHT_SHAFTS
		float depth0 = texelFetch(shadowtex0, shadow_texel, 0).x;
		float depth1 = texelFetch(shadowtex1, shadow_texel, 0).x;
		vec3  color = texelFetch(shadowcolor0, shadow_texel, 0).rgb;
		float color_weight = step(depth0, shadow_screen_pos.z) * step(eps, max_of(color));

		color = color * color_weight + (1.0 - color_weight);

		vec3 shadow = step(shadow_screen_pos.z, depth1) * color;
	#else
		float depth1 = texelFetch(shadowtex1, shadow_texel, 0).x;
		float shadow = step(float(clamp01(shadow_screen_pos) == shadow_screen_pos) * shadow_screen_pos.z, depth1);
	#endif
#else
		#define shadow 1.0
#endif

		vec2 density = air_fog_density(world_pos) * step_length;

		vec3 step_optical_depth = air_fog_coeff[1] * density;
		vec3 step_transmittance = exp(-step_optical_depth);
		vec3 step_transmitted_fraction = (1.0 - step_transmittance) / max(step_optical_depth, eps);

		vec3 visible_scattering = step_transmitted_fraction * transmittance;

		light_sun[0] += visible_scattering * density.x * shadow;
		light_sun[1] += visible_scattering * density.y * shadow;
		light_sky[0] += visible_scattering * density.x;
		light_sky[1] += visible_scattering * density.y;

		transmittance *= step_transmittance;
	}

	light_sun[0] *= air_fog_coeff[0][0];
	light_sun[1] *= air_fog_coeff[0][1];
	light_sky[0] *= air_fog_coeff[0][0] * eye_skylight;
	light_sky[1] *= air_fog_coeff[0][1] * eye_skylight;

	if (!sky) {
		// Skylight falloff
		light_sky[0] *= skylight;
		light_sky[1] *= skylight;
	}

	float LoV = dot(world_dir, light_dir);
	float mie_phase = 0.7 * henyey_greenstein_phase(LoV, 0.5) + 0.3 * henyey_greenstein_phase(LoV, -0.2);

	/*
	// Single scattering
	vec3 scattering  = light_color * (light_sun * vec2(isotropic_phase, mie_phase));
	     scattering += sky_color * (light_sky * vec2(isotropic_phase));
	/*/
	// Multiple scattering
	vec3 scattering = vec3(0.0);
	float scatter_amount = 1.0;

	for (int i = 0; i < 4; ++i) {
		scattering += scatter_amount * (light_sun * vec2(isotropic_phase, mie_phase)) * light_color;
		scattering += scatter_amount * (light_sky * vec2(isotropic_phase)) * sky_color;

		scatter_amount *= 0.5;
		mie_phase = mix(mie_phase, isotropic_phase, 0.3);
	}
	//*/

	scattering *= 1.0 - blindness;

	return mat2x3(scattering, transmittance);
}

void main() {
	ivec2 fog_texel  = ivec2(gl_FragCoord.xy);
	ivec2 view_texel = ivec2(gl_FragCoord.xy * taau_render_scale * rcp(VL_RENDER_SCALE));

	float depth   = texelFetch(depthtex1, view_texel, 0).x;
	vec4 gbuffer_data_0 = texelFetch(colortex1, view_texel, 0);

	float skylight = unpack_unorm_2x8(gbuffer_data_0.w).y;

	vec3 view_pos  = screen_to_view_space(vec3(uv, depth), true);
	vec3 scene_pos = view_to_scene_space(view_pos);
	vec3 world_pos = scene_pos + cameraPosition;

	float dither = texelFetch(noisetex, fog_texel & 511, 0).b;
	      dither = r1(frameCounter, dither);

	switch (isEyeInWater) {
		case 0:
			vec3 world_start_pos = gbufferModelViewInverse[3].xyz + cameraPosition;
			vec3 world_end_pos   = world_pos;

			mat2x3 fog = raymarch_air_fog(world_start_pos, world_end_pos, depth == 1.0, skylight, dither);

			fog_scattering    = fog[0];
			fog_transimttance = fog[1];

			break;

		default:
			fog_scattering    = vec3(0.0);
			fog_transimttance = vec3(1.0);
			break;

		// Prevent potential game crash due to empty switch statement
		case -1:
			break;
	}
}
