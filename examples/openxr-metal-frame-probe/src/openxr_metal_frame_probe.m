// Copyright 2026
// SPDX-License-Identifier: BSL-1.0

#define XR_USE_GRAPHICS_API_METAL 1

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

#include "openxr/openxr.h"
#include "openxr/openxr_loader_negotiation.h"
#include "openxr/openxr_platform.h"

struct probe_swapchain
{
	XrSwapchain handle;
	XrSwapchainCreateInfo create_info;
	XrSwapchainImageMetalKHR *images;
	uint32_t image_count;
};

struct instance_extensions
{
	bool metal_enable;
};

enum probe_pattern
{
	PROBE_PATTERN_STEREO_RG = 0,
	PROBE_PATTERN_SOLID_MAGENTA = 1,
	PROBE_PATTERN_SOLID_WHITE = 2,
	PROBE_PATTERN_GEOMETRY_CARD = 3,
	PROBE_PATTERN_GEOMETRY_QUADRANTS = 4,
	PROBE_PATTERN_WORLD_CARD = 5,
	PROBE_PATTERN_WORLD_GRID = 6,
	PROBE_PATTERN_WORLD_GRID_PASSTHROUGH = 7,
	PROBE_PATTERN_WORLD_GEOMETRY = 8,
	PROBE_PATTERN_SOLID_WHITE_PASSTHROUGH = 9,
};

struct probe_world_vertex
{
	vector_float4 position;
	vector_float2 uv;
};

struct probe_world_color_vertex
{
	vector_float4 position;
	vector_float4 color;
};

struct probe_world_anchor
{
	vector_float3 head_center;
	vector_float3 center;
	vector_float3 right;
	vector_float3 up;
	vector_float3 forward;
	float distance;
};

static int
fail_xr(const char *what, XrResult result)
{
	fprintf(stderr, "%s failed: %d\n", what, result);
	return 1;
}

static int
fail_msg(const char *what)
{
	fprintf(stderr, "%s\n", what);
	return 1;
}

static int
get_proc(PFN_xrGetInstanceProcAddr get_instance_proc_addr,
         XrInstance instance,
         const char *name,
         PFN_xrVoidFunction *out_fn)
{
	XrResult result = get_instance_proc_addr(instance, name, out_fn);
	if (result != XR_SUCCESS) {
		return fail_xr(name, result);
	}

	if (*out_fn == NULL) {
		fprintf(stderr, "%s returned NULL function pointer\n", name);
		return 1;
	}

	return 0;
}

static uint32_t
get_frame_limit(void)
{
	const char *value = getenv("WIVRN_OPENXR_METAL_PROBE_FRAMES");
	if (value == NULL || value[0] == '\0') {
		return 3;
	}

	char *end = NULL;
	long parsed = strtol(value, &end, 10);
	if (end == value || *end != '\0' || parsed < 1 || parsed > 108000) {
		fprintf(stderr, "Invalid WIVRN_OPENXR_METAL_PROBE_FRAMES=%s, expected integer in [1,108000]\n", value);
		return 0;
	}

	return (uint32_t)parsed;
}

static enum probe_pattern
get_probe_pattern(void)
{
	const char *value = getenv("WIVRN_OPENXR_METAL_PROBE_PATTERN");
	if (value == NULL || value[0] == '\0' || strcmp(value, "stereo-rg") == 0) {
		return PROBE_PATTERN_STEREO_RG;
	}
	if (strcmp(value, "solid-magenta") == 0) {
		return PROBE_PATTERN_SOLID_MAGENTA;
	}
	if (strcmp(value, "solid-white") == 0) {
		return PROBE_PATTERN_SOLID_WHITE;
	}
	if (strcmp(value, "geometry-card") == 0) {
		return PROBE_PATTERN_GEOMETRY_CARD;
	}
	if (strcmp(value, "geometry-quadrants") == 0) {
		return PROBE_PATTERN_GEOMETRY_QUADRANTS;
	}
	if (strcmp(value, "world-card") == 0) {
		return PROBE_PATTERN_WORLD_CARD;
	}
	if (strcmp(value, "world-grid") == 0) {
		return PROBE_PATTERN_WORLD_GRID;
	}
	if (strcmp(value, "world-grid-passthrough") == 0) {
		return PROBE_PATTERN_WORLD_GRID_PASSTHROUGH;
	}
	if (strcmp(value, "world-geometry") == 0) {
		return PROBE_PATTERN_WORLD_GEOMETRY;
	}
	if (strcmp(value, "solid-white-passthrough") == 0) {
		return PROBE_PATTERN_SOLID_WHITE_PASSTHROUGH;
	}

	fprintf(stderr,
	        "Unknown WIVRN_OPENXR_METAL_PROBE_PATTERN=%s, expected stereo-rg, solid-magenta, solid-white, solid-white-passthrough, geometry-card, geometry-quadrants, world-card, world-grid, world-grid-passthrough, or world-geometry\n",
	        value);
	return PROBE_PATTERN_STEREO_RG;
}

static const char *
probe_pattern_name(enum probe_pattern pattern)
{
	switch (pattern) {
	case PROBE_PATTERN_STEREO_RG: return "stereo-rg";
	case PROBE_PATTERN_SOLID_MAGENTA: return "solid-magenta";
	case PROBE_PATTERN_SOLID_WHITE: return "solid-white";
	case PROBE_PATTERN_GEOMETRY_CARD: return "geometry-card";
	case PROBE_PATTERN_GEOMETRY_QUADRANTS: return "geometry-quadrants";
	case PROBE_PATTERN_WORLD_CARD: return "world-card";
	case PROBE_PATTERN_WORLD_GRID: return "world-grid";
	case PROBE_PATTERN_WORLD_GRID_PASSTHROUGH: return "world-grid-passthrough";
	case PROBE_PATTERN_WORLD_GEOMETRY: return "world-geometry";
	case PROBE_PATTERN_SOLID_WHITE_PASSTHROUGH: return "solid-white-passthrough";
	default: return "unknown";
	}
}

static int
wait_for_session_state(PFN_xrPollEvent xrPollEvent,
                       XrInstance instance,
                       XrSessionState target_state,
                       XrSessionState *out_current_state)
{
	for (;;) {
		XrEventDataBuffer event = {
		    .type = XR_TYPE_EVENT_DATA_BUFFER,
		};
		XrResult xr = xrPollEvent(instance, &event);
		if (xr == XR_EVENT_UNAVAILABLE) {
			usleep(1000);
			continue;
		}
		if (xr != XR_SUCCESS) {
			return fail_xr("xrPollEvent", xr);
		}

		if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
			XrEventDataSessionStateChanged *changed = (XrEventDataSessionStateChanged *)&event;
			if (out_current_state != NULL) {
				*out_current_state = changed->state;
			}
			fprintf(stdout, "Session state changed: %d\n", changed->state);
			if (changed->state == target_state) {
				return 0;
			}
			if (changed->state == XR_SESSION_STATE_EXITING || changed->state == XR_SESSION_STATE_LOSS_PENDING) {
				return fail_msg("Session exited before reaching target state");
			}
		}
	}
}

static bool
have_int64(const int64_t *values, uint32_t value_count, int64_t target)
{
	for (uint32_t i = 0; i < value_count; ++i) {
		if (values[i] == target) {
			return true;
		}
	}

	return false;
}

static int64_t
choose_swapchain_format(const int64_t *formats, uint32_t format_count)
{
	if (have_int64(formats, format_count, MTLPixelFormatBGRA8Unorm)) {
		return MTLPixelFormatBGRA8Unorm;
	}
	if (have_int64(formats, format_count, MTLPixelFormatRGBA8Unorm)) {
		return MTLPixelFormatRGBA8Unorm;
	}

	return format_count > 0 ? formats[0] : 0;
}

static NSString *const kProbeGeometryShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VsOut {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
};\n\
\n\
vertex VsOut vs_main(uint vertex_id [[vertex_id]]) {\n\
    const float2 positions[6] = {\n\
        float2(-0.66, -0.46), float2(0.66, -0.46), float2(0.66, 0.46),\n\
        float2(-0.66, -0.46), float2(0.66, 0.46), float2(-0.66, 0.46)\n\
    };\n\
    const float2 uvs[6] = {\n\
        float2(0.0, 1.0), float2(1.0, 1.0), float2(1.0, 0.0),\n\
        float2(0.0, 1.0), float2(1.0, 0.0), float2(0.0, 0.0)\n\
    };\n\
    VsOut out;\n\
    out.position = float4(positions[vertex_id], 0.0, 1.0);\n\
    out.uv = uvs[vertex_id];\n\
    return out;\n\
}\n\
\n\
fragment float4 fs_main(VsOut in [[stage_in]]) {\n\
    float2 centered = in.uv - float2(0.5, 0.5);\n\
    if (in.uv.y < 0.22) {\n\
        return float4(0.14, 0.12, 0.10, 1.0);\n\
    }\n\
\n\
    float2 ring_center = float2(0.5, 0.56);\n\
    float dist = distance(in.uv, ring_center);\n\
    if (dist < 0.09) {\n\
        return float4(0.18, 0.84, 0.90, 1.0);\n\
    }\n\
    if (dist < 0.16) {\n\
        return float4(0.97, 0.89, 0.24, 1.0);\n\
    }\n\
    if (dist < 0.23) {\n\
        return float4(0.16, 0.14, 0.12, 1.0);\n\
    }\n\
\n\
    float vertical_band = smoothstep(0.0, 0.02, 0.035 - fabs(centered.x));\n\
    float4 base = float4(0.96, 0.44, 0.15, 1.0);\n\
    float4 band = float4(0.90, 0.60, 0.30, 1.0);\n\
    return mix(base, band, vertical_band * 0.35);\n\
}\n\
";

static NSString *const kProbeQuadrantsShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VsOut {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
};\n\
\n\
vertex VsOut vs_main(uint vertex_id [[vertex_id]]) {\n\
    const float2 positions[6] = {\n\
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),\n\
        float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)\n\
    };\n\
    const float2 uvs[6] = {\n\
        float2(0.0, 1.0), float2(1.0, 1.0), float2(1.0, 0.0),\n\
        float2(0.0, 1.0), float2(1.0, 0.0), float2(0.0, 0.0)\n\
    };\n\
    VsOut out;\n\
    out.position = float4(positions[vertex_id], 0.0, 1.0);\n\
    out.uv = uvs[vertex_id];\n\
    return out;\n\
}\n\
\n\
fragment float4 fs_main(VsOut in [[stage_in]]) {\n\
    bool left = in.uv.x < 0.5;\n\
    bool top = in.uv.y < 0.5;\n\
    if (left && top) {\n\
        return float4(0.95, 0.16, 0.18, 1.0);\n\
    }\n\
    if (!left && top) {\n\
        return float4(0.10, 0.90, 0.20, 1.0);\n\
    }\n\
    if (left && !top) {\n\
        return float4(0.08, 0.88, 0.95, 1.0);\n\
    }\n\
    return float4(0.98, 0.86, 0.16, 1.0);\n\
}\n\
";

static NSString *const kProbeWorldCardShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VertexIn {\n\
    float4 position;\n\
    float2 uv;\n\
};\n\
\n\
struct VsOut {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
};\n\
\n\
vertex VsOut vs_main(const device VertexIn *vertices [[buffer(0)]], uint vertex_id [[vertex_id]]) {\n\
    VsOut out;\n\
    out.position = vertices[vertex_id].position;\n\
    out.uv = vertices[vertex_id].uv;\n\
    return out;\n\
}\n\
\n\
fragment float4 fs_main(VsOut in [[stage_in]]) {\n\
    float2 centered = in.uv - float2(0.5, 0.5);\n\
    if (in.uv.y < 0.22) {\n\
        return float4(0.14, 0.12, 0.10, 1.0);\n\
    }\n\
\n\
    float2 ring_center = float2(0.5, 0.56);\n\
    float dist = distance(in.uv, ring_center);\n\
    if (dist < 0.09) {\n\
        return float4(0.18, 0.84, 0.90, 1.0);\n\
    }\n\
    if (dist < 0.16) {\n\
        return float4(0.97, 0.89, 0.24, 1.0);\n\
    }\n\
    if (dist < 0.23) {\n\
        return float4(0.16, 0.14, 0.12, 1.0);\n\
    }\n\
\n\
    float vertical_band = smoothstep(0.0, 0.02, 0.035 - fabs(centered.x));\n\
    float4 base = float4(0.96, 0.44, 0.15, 1.0);\n\
    float4 band = float4(0.90, 0.60, 0.30, 1.0);\n\
    return mix(base, band, vertical_band * 0.35);\n\
}\n\
";

static NSString *const kProbeWorldGridShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VertexIn {\n\
    float4 position;\n\
    float2 uv;\n\
};\n\
\n\
struct VsOut {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
};\n\
\n\
vertex VsOut vs_main(const device VertexIn *vertices [[buffer(0)]], uint vertex_id [[vertex_id]]) {\n\
    VsOut out;\n\
    out.position = vertices[vertex_id].position;\n\
    out.uv = vertices[vertex_id].uv;\n\
    return out;\n\
}\n\
\n\
fragment float4 fs_main(VsOut in [[stage_in]]) {\n\
    float2 uv = in.uv;\n\
    float2 centered = uv - float2(0.5, 0.5);\n\
    float dist = length(centered);\n\
\n\
    // Grid lines every 0.1 UV (roughly 10 degree increments at 2m distance)\n\
    float grid_x = 1.0 - smoothstep(0.002, 0.006, fabs(fract(uv.x * 10.0) - 0.5) / 10.0);\n\
    float grid_y = 1.0 - smoothstep(0.002, 0.006, fabs(fract(uv.y * 10.0) - 0.5) / 10.0);\n\
    float grid = max(grid_x, grid_y);\n\
\n\
    // Thicker center crosshair\n\
    float cross_x = 1.0 - smoothstep(0.001, 0.004, fabs(centered.y));\n\
    float cross_y = 1.0 - smoothstep(0.001, 0.004, fabs(centered.x));\n\
    float cross = max(cross_x, cross_y);\n\
\n\
    // Bullseye rings\n\
    float ring1 = 1.0 - smoothstep(0.002, 0.005, fabs(dist - 0.05));\n\
    float ring2 = 1.0 - smoothstep(0.002, 0.005, fabs(dist - 0.15));\n\
    float ring3 = 1.0 - smoothstep(0.002, 0.005, fabs(dist - 0.30));\n\
    float rings = max(ring1, max(ring2, ring3));\n\
\n\
    // Background: soft gradient from light blue center to gray edges\n\
    float4 bg = mix(float4(0.85, 0.92, 0.98, 1.0), float4(0.65, 0.68, 0.72, 1.0), dist * 1.5);\n\
\n\
    // Grid lines in dark gray\n\
    float4 grid_color = float4(0.3, 0.3, 0.35, 1.0);\n\
    float4 cross_color = float4(0.9, 0.15, 0.1, 1.0);\n\
    float4 ring_color = float4(0.1, 0.1, 0.8, 1.0);\n\
\n\
    float4 color = bg;\n\
    color = mix(color, grid_color, grid * 0.7);\n\
    color = mix(color, ring_color, rings * 0.8);\n\
    color = mix(color, cross_color, cross * 0.9);\n\
\n\
    return color;\n\
}\n\
";

static NSString *const kProbeWorldGridPassthroughShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VertexIn {\n\
    float4 position;\n\
    float2 uv;\n\
};\n\
\n\
struct VsOut {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
};\n\
\n\
vertex VsOut vs_main(const device VertexIn *vertices [[buffer(0)]], uint vertex_id [[vertex_id]]) {\n\
    VsOut out;\n\
    out.position = vertices[vertex_id].position;\n\
    out.uv = vertices[vertex_id].uv;\n\
    return out;\n\
}\n\
\n\
fragment float4 fs_main(VsOut in [[stage_in]]) {\n\
    float2 uv = in.uv;\n\
    float2 centered = uv - float2(0.5, 0.5);\n\
    float dist = length(centered);\n\
\n\
    // Grid lines every 0.1 UV\n\
    float grid_x = 1.0 - smoothstep(0.002, 0.006, fabs(fract(uv.x * 10.0) - 0.5) / 10.0);\n\
    float grid_y = 1.0 - smoothstep(0.002, 0.006, fabs(fract(uv.y * 10.0) - 0.5) / 10.0);\n\
    float grid = max(grid_x, grid_y);\n\
\n\
    // Thicker center crosshair\n\
    float cross_x = 1.0 - smoothstep(0.001, 0.004, fabs(centered.y));\n\
    float cross_y = 1.0 - smoothstep(0.001, 0.004, fabs(centered.x));\n\
    float cross = max(cross_x, cross_y);\n\
\n\
    // Bullseye rings\n\
    float ring1 = 1.0 - smoothstep(0.002, 0.005, fabs(dist - 0.05));\n\
    float ring2 = 1.0 - smoothstep(0.002, 0.005, fabs(dist - 0.15));\n\
    float ring3 = 1.0 - smoothstep(0.002, 0.005, fabs(dist - 0.30));\n\
    float rings = max(ring1, max(ring2, ring3));\n\
\n\
    // Combine all line features\n\
    float lines = max(grid * 0.7, max(rings * 0.8, cross * 0.9));\n\
\n\
    // Transparent background, opaque lines overlaid on passthrough\n\
    float4 grid_color = float4(0.3, 0.3, 0.35, 1.0);\n\
    float4 cross_color = float4(0.9, 0.15, 0.1, 1.0);\n\
    float4 ring_color = float4(0.1, 0.1, 0.8, 1.0);\n\
\n\
    float4 color = float4(0.0, 0.0, 0.0, 0.0);\n\
    color = mix(color, grid_color, grid * 0.7);\n\
    color = mix(color, ring_color, rings * 0.8);\n\
    color = mix(color, cross_color, cross * 0.9);\n\
\n\
    return color;\n\
}\n\
";

static NSString *const kProbeWorldGeometryShader = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VertexIn {\n\
    float4 position;\n\
    float4 color;\n\
};\n\
\n\
struct VsOut {\n\
    float4 position [[position]];\n\
    float4 color;\n\
};\n\
\n\
vertex VsOut vs_main(const device VertexIn *vertices [[buffer(0)]], uint vertex_id [[vertex_id]]) {\n\
    VsOut out;\n\
    out.position = vertices[vertex_id].position;\n\
    out.color = vertices[vertex_id].color;\n\
    return out;\n\
}\n\
\n\
fragment float4 fs_main(VsOut in [[stage_in]]) {\n\
    return in.color;\n\
}\n\
";

static id<MTLRenderPipelineState>
create_probe_geometry_pipeline(id<MTLDevice> metal_device, MTLPixelFormat color_format, enum probe_pattern pattern)
{
	NSString *shader_source = kProbeGeometryShader;
	if (pattern == PROBE_PATTERN_GEOMETRY_QUADRANTS) {
		shader_source = kProbeQuadrantsShader;
	} else if (pattern == PROBE_PATTERN_WORLD_CARD) {
		shader_source = kProbeWorldCardShader;
	} else if (pattern == PROBE_PATTERN_WORLD_GRID) {
		shader_source = kProbeWorldGridShader;
	} else if (pattern == PROBE_PATTERN_WORLD_GRID_PASSTHROUGH) {
		shader_source = kProbeWorldGridPassthroughShader;
	} else if (pattern == PROBE_PATTERN_WORLD_GEOMETRY) {
		shader_source = kProbeWorldGeometryShader;
	}
	NSError *error = nil;
	id<MTLLibrary> library = [metal_device newLibraryWithSource:shader_source options:nil error:&error];
	if (library == nil) {
		fprintf(stderr,
		        "Failed to compile probe Metal shader: %s\n",
		        error.localizedDescription.UTF8String);
		return nil;
	}

	id<MTLFunction> vertex_fn = [library newFunctionWithName:@"vs_main"];
	id<MTLFunction> fragment_fn = [library newFunctionWithName:@"fs_main"];
	if (vertex_fn == nil || fragment_fn == nil) {
		fprintf(stderr, "Failed to create probe Metal functions\n");
		return nil;
	}

	MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
	descriptor.label = @"wivrn macos probe geometry pipeline";
	descriptor.vertexFunction = vertex_fn;
	descriptor.fragmentFunction = fragment_fn;
	descriptor.colorAttachments[0].pixelFormat = color_format;

	id<MTLRenderPipelineState> pipeline = [metal_device newRenderPipelineStateWithDescriptor:descriptor
	                                                                                   error:&error];
	if (pipeline == nil) {
		fprintf(stderr,
		        "Failed to create probe Metal pipeline: %s\n",
		        error.localizedDescription.UTF8String);
	}
	return pipeline;
}

static bool
project_world_point(const XrView *view, vector_float3 world_position, vector_float4 *out_position)
{
	const vector_float3 eye_position = {
	    view->pose.position.x,
	    view->pose.position.y,
	    view->pose.position.z,
	};
	const simd_quatf eye_orientation = simd_quaternion(
	    view->pose.orientation.x,
	    view->pose.orientation.y,
	    view->pose.orientation.z,
	    view->pose.orientation.w);
	const simd_quatf inv_orientation = simd_conjugate(eye_orientation);

	const float tan_left = tanf(view->fov.angleLeft);
	const float tan_right = tanf(view->fov.angleRight);
	const float tan_down = tanf(view->fov.angleDown);
	const float tan_up = tanf(view->fov.angleUp);
	const float tan_width = tan_right - tan_left;
	const float tan_height = tan_up - tan_down;
	if (fabsf(tan_width) < 0.00001f || fabsf(tan_height) < 0.00001f) {
		return false;
	}

	const vector_float3 rel_world = world_position - eye_position;
	const vector_float3 eye_space = simd_act(inv_orientation, rel_world);
	const float forward = fmaxf(-eye_space.z, 0.05f);
	const float tan_x = eye_space.x / forward;
	const float tan_y = eye_space.y / forward;
	const float ndc_x = ((tan_x - tan_left) / tan_width) * 2.0f - 1.0f;
	const float ndc_y = ((tan_y - tan_down) / tan_height) * 2.0f - 1.0f;
	*out_position = (vector_float4){ndc_x * forward, ndc_y * forward, 0.5f * forward, forward};
	return true;
}

static bool
build_world_card_vertices(const XrView *view,
                          const vector_float3 world_positions[4],
                          struct probe_world_vertex out_vertices[6])
{
	const vector_float2 uvs[4] = {
	    {0.0f, 1.0f},
	    {1.0f, 1.0f},
	    {1.0f, 0.0f},
	    {0.0f, 0.0f},
	};
	const uint32_t indices[6] = {0, 1, 2, 0, 2, 3};

	for (uint32_t i = 0; i < 6; ++i) {
		const uint32_t index = indices[i];
		if (!project_world_point(view, world_positions[index], &out_vertices[i].position)) {
			return false;
		}
		out_vertices[i].uv = uvs[index];
	}

	return true;
}

static void
compute_world_anchor_from_views(const XrView views[2], float distance, struct probe_world_anchor *out_anchor)
{
	const vector_float3 left_eye = {
	    views[0].pose.position.x,
	    views[0].pose.position.y,
	    views[0].pose.position.z,
	};
	const vector_float3 right_eye = {
	    views[1].pose.position.x,
	    views[1].pose.position.y,
	    views[1].pose.position.z,
	};
	const vector_float3 head_center = (left_eye + right_eye) * 0.5f;
	const simd_quatf head_orientation = simd_quaternion(
	    views[0].pose.orientation.x,
	    views[0].pose.orientation.y,
	    views[0].pose.orientation.z,
	    views[0].pose.orientation.w);

	out_anchor->head_center = head_center;
	out_anchor->forward = simd_normalize(simd_act(head_orientation, (vector_float3){0.0f, 0.0f, -1.0f}));
	out_anchor->right = simd_normalize(simd_act(head_orientation, (vector_float3){1.0f, 0.0f, 0.0f}));
	out_anchor->up = simd_normalize(simd_act(head_orientation, (vector_float3){0.0f, 1.0f, 0.0f}));
	out_anchor->distance = distance;
	out_anchor->center = head_center + out_anchor->forward * distance;
}

static void
build_world_quad_from_anchor(const struct probe_world_anchor *anchor,
                             float half_width,
                             float half_height,
                             vector_float3 out_world_positions[4])
{
	out_world_positions[0] = anchor->center - anchor->right * half_width - anchor->up * half_height;
	out_world_positions[1] = anchor->center + anchor->right * half_width - anchor->up * half_height;
	out_world_positions[2] = anchor->center + anchor->right * half_width + anchor->up * half_height;
	out_world_positions[3] = anchor->center - anchor->right * half_width + anchor->up * half_height;
}

static bool
append_projected_quad(const XrView *view,
                      const vector_float3 world_positions[4],
                      vector_float4 color,
                      struct probe_world_color_vertex *out_vertices,
                      uint32_t max_vertex_count,
                      uint32_t *inout_vertex_count)
{
	const uint32_t indices[6] = {0, 1, 2, 0, 2, 3};
	if (*inout_vertex_count + 6 > max_vertex_count) {
		return false;
	}

	for (uint32_t i = 0; i < 6; ++i) {
		struct probe_world_color_vertex *out_vertex = &out_vertices[*inout_vertex_count + i];
		if (!project_world_point(view, world_positions[indices[i]], &out_vertex->position)) {
			return false;
		}
		out_vertex->color = color;
	}
	*inout_vertex_count += 6;
	return true;
}

static bool
append_centered_world_quad(const XrView *view,
                           vector_float3 center,
                           vector_float3 right_axis,
                           vector_float3 up_axis,
                           float half_width,
                           float half_height,
                           vector_float4 color,
                           struct probe_world_color_vertex *out_vertices,
                           uint32_t max_vertex_count,
                           uint32_t *inout_vertex_count)
{
	vector_float3 quad[4];
	quad[0] = center - right_axis * half_width - up_axis * half_height;
	quad[1] = center + right_axis * half_width - up_axis * half_height;
	quad[2] = center + right_axis * half_width + up_axis * half_height;
	quad[3] = center - right_axis * half_width + up_axis * half_height;
	return append_projected_quad(view, quad, color, out_vertices, max_vertex_count, inout_vertex_count);
}

static bool
build_world_geometry_vertices(const XrView *view,
                              const struct probe_world_anchor *anchor,
                              struct probe_world_color_vertex *out_vertices,
                              uint32_t max_vertex_count,
                              uint32_t *out_vertex_count)
{
	uint32_t vertex_count = 0;
	const float frame_half_width = 1.65f;
	const float frame_half_height = 1.15f;
	const float frame_thickness = 0.035f;
	const float cross_length = 0.34f;
	const float cross_thickness = 0.018f;
	const float marker_half = 0.09f;
	const float marker_y = -0.42f;
	const vector_float4 top_color = {0.96f, 0.80f, 0.20f, 1.0f};
	const vector_float4 bottom_color = {0.20f, 0.82f, 0.88f, 1.0f};
	const vector_float4 left_color = {0.92f, 0.26f, 0.22f, 1.0f};
	const vector_float4 right_color = {0.24f, 0.88f, 0.32f, 1.0f};
	const vector_float4 cross_color = {0.96f, 0.96f, 0.98f, 1.0f};
	const vector_float4 near_color = {0.98f, 0.52f, 0.18f, 1.0f};
	const vector_float4 mid_color = {0.24f, 0.78f, 0.98f, 1.0f};
	const vector_float4 far_color = {0.78f, 0.36f, 0.98f, 1.0f};

	if (!append_centered_world_quad(view,
	                                anchor->center + anchor->up * frame_half_height,
	                                anchor->right,
	                                anchor->up,
	                                frame_half_width,
	                                frame_thickness,
	                                top_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count) ||
	    !append_centered_world_quad(view,
	                                anchor->center - anchor->up * frame_half_height,
	                                anchor->right,
	                                anchor->up,
	                                frame_half_width,
	                                frame_thickness,
	                                bottom_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count) ||
	    !append_centered_world_quad(view,
	                                anchor->center - anchor->right * frame_half_width,
	                                anchor->right,
	                                anchor->up,
	                                frame_thickness,
	                                frame_half_height,
	                                left_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count) ||
	    !append_centered_world_quad(view,
	                                anchor->center + anchor->right * frame_half_width,
	                                anchor->right,
	                                anchor->up,
	                                frame_thickness,
	                                frame_half_height,
	                                right_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count) ||
	    !append_centered_world_quad(view,
	                                anchor->center,
	                                anchor->right,
	                                anchor->up,
	                                cross_length,
	                                cross_thickness,
	                                cross_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count) ||
	    !append_centered_world_quad(view,
	                                anchor->center,
	                                anchor->right,
	                                anchor->up,
	                                cross_thickness,
	                                cross_length,
	                                cross_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count)) {
		return false;
	}

	const vector_float3 near_center =
	    anchor->head_center + anchor->forward * 1.05f - anchor->right * 0.48f + anchor->up * marker_y;
	const vector_float3 mid_center =
	    anchor->head_center + anchor->forward * 1.55f + anchor->up * marker_y;
	const vector_float3 far_center =
	    anchor->head_center + anchor->forward * 2.25f + anchor->right * 0.48f + anchor->up * marker_y;
	if (!append_centered_world_quad(view,
	                                near_center,
	                                anchor->right,
	                                anchor->up,
	                                marker_half,
	                                marker_half,
	                                near_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count) ||
	    !append_centered_world_quad(view,
	                                mid_center,
	                                anchor->right,
	                                anchor->up,
	                                marker_half,
	                                marker_half,
	                                mid_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count) ||
	    !append_centered_world_quad(view,
	                                far_center,
	                                anchor->right,
	                                anchor->up,
	                                marker_half,
	                                marker_half,
	                                far_color,
	                                out_vertices,
	                                max_vertex_count,
	                                &vertex_count)) {
		return false;
	}

	*out_vertex_count = vertex_count;
	return true;
}

static void
anchor_world_grid_from_views(const XrView views[2], vector_float3 out_world_positions[4])
{
	struct probe_world_anchor anchor = {0};
	compute_world_anchor_from_views(views, 2.0f, &anchor);
	build_world_quad_from_anchor(&anchor, 2.8f, 2.4f, out_world_positions);
}

static void
anchor_world_card_from_views(const XrView views[2], vector_float3 out_world_positions[4])
{
	struct probe_world_anchor anchor = {0};
	compute_world_anchor_from_views(views, 1.35f, &anchor);
	build_world_quad_from_anchor(&anchor, 0.70f, 0.50f, out_world_positions);
}

static void
anchor_world_geometry_from_views(const XrView views[2], struct probe_world_anchor *out_anchor)
{
	compute_world_anchor_from_views(views, 1.8f, out_anchor);
}

static int
render_pattern_to_swapchain_image(id<MTLCommandQueue> command_queue,
                                  id<MTLRenderPipelineState> geometry_pipeline,
                                  XrSwapchainImageMetalKHR *image,
                                  enum probe_pattern pattern,
                                  const XrView *view,
                                  const struct probe_world_anchor *world_anchor,
                                  const vector_float3 world_card_positions[4],
                                  uint32_t view_index,
                                  uint32_t frame_index)
{
	id<MTLTexture> texture = (__bridge id<MTLTexture>)image->texture;
	if (texture == nil) {
		return fail_msg("Swapchain image returned NULL MTLTexture");
	}

	MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
	descriptor.colorAttachments[0].texture = texture;
	descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
	descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
	(void)frame_index;
	switch (pattern) {
	case PROBE_PATTERN_SOLID_MAGENTA:
		descriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.0, 1.0, 1.0);
		break;
	case PROBE_PATTERN_SOLID_WHITE:
	case PROBE_PATTERN_SOLID_WHITE_PASSTHROUGH:
		descriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
		break;
	case PROBE_PATTERN_GEOMETRY_CARD:
	case PROBE_PATTERN_GEOMETRY_QUADRANTS:
	case PROBE_PATTERN_WORLD_CARD:
		descriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.0, 1.0, 1.0);
		break;
	case PROBE_PATTERN_WORLD_GRID:
		descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.15, 0.15, 0.18, 1.0);
		break;
	case PROBE_PATTERN_WORLD_GRID_PASSTHROUGH:
		descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
		break;
	case PROBE_PATTERN_WORLD_GEOMETRY:
		descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.08, 0.09, 0.11, 1.0);
		break;
	case PROBE_PATTERN_STEREO_RG:
	default:
		if (view_index == 0) {
			descriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.0, 0.0, 1.0);
		} else {
			descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 1.0, 0.0, 1.0);
		}
		break;
	}

	id<MTLCommandBuffer> command_buffer = [command_queue commandBuffer];
	if (command_buffer == nil) {
		return fail_msg("Failed to allocate Metal command buffer");
	}

	id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:descriptor];
	if (encoder == nil) {
		return fail_msg("Failed to create Metal render command encoder");
	}
	if (pattern == PROBE_PATTERN_GEOMETRY_CARD || pattern == PROBE_PATTERN_GEOMETRY_QUADRANTS ||
	    pattern == PROBE_PATTERN_WORLD_CARD || pattern == PROBE_PATTERN_WORLD_GRID ||
	    pattern == PROBE_PATTERN_WORLD_GRID_PASSTHROUGH || pattern == PROBE_PATTERN_WORLD_GEOMETRY) {
		if (geometry_pipeline == nil) {
			return fail_msg("Missing geometry pipeline for geometry probe pattern");
		}
		[encoder setRenderPipelineState:geometry_pipeline];
		if (pattern == PROBE_PATTERN_WORLD_CARD || pattern == PROBE_PATTERN_WORLD_GRID ||
		    pattern == PROBE_PATTERN_WORLD_GRID_PASSTHROUGH) {
			if (view == NULL) {
				return fail_msg("Missing XrView for world-card/grid probe pattern");
			}
			struct probe_world_vertex vertices[6];
			if (!build_world_card_vertices(view, world_card_positions, vertices)) {
				return fail_msg("Failed to build world-card/grid probe vertices");
			}
			[encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		} else if (pattern == PROBE_PATTERN_WORLD_GEOMETRY) {
			if (view == NULL || world_anchor == NULL) {
				return fail_msg("Missing XrView/world anchor for world-geometry probe pattern");
			}
			struct probe_world_color_vertex vertices[96];
			uint32_t vertex_count = 0;
			if (!build_world_geometry_vertices(view, world_anchor, vertices, 96, &vertex_count)) {
				return fail_msg("Failed to build world-geometry probe vertices");
			}
			[encoder setVertexBytes:vertices length:(NSUInteger)(sizeof(vertices[0]) * vertex_count) atIndex:0];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertex_count];
		} else {
			[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		}
	}

	[encoder endEncoding];
	[command_buffer commit];
	[command_buffer waitUntilCompleted];
	if (command_buffer.status != MTLCommandBufferStatusCompleted) {
		NSString *description = command_buffer.error != nil ? command_buffer.error.localizedDescription : @"unknown Metal failure";
		fprintf(stderr, "Metal command buffer failed: %s\n", description.UTF8String);
		return 1;
	}

	return 0;
}

static void
log_swapchain_image_sample(XrSwapchainImageMetalKHR *image, uint32_t view_index, uint32_t frame_index)
{
	id<MTLTexture> texture = (__bridge id<MTLTexture>)image->texture;
	if (texture == nil || texture.width == 0 || texture.height == 0) {
		return;
	}

	uint8_t texel0[4] = {0};
	uint8_t texel_center[4] = {0};
	const NSUInteger center_x = texture.width / 2u;
	const NSUInteger center_y = texture.height / 2u;

	[texture getBytes:texel0
	         bytesPerRow:sizeof(texel0)
	          fromRegion:MTLRegionMake2D(0, 0, 1, 1)
	         mipmapLevel:0];
	[texture getBytes:texel_center
	         bytesPerRow:sizeof(texel_center)
	          fromRegion:MTLRegionMake2D(center_x, center_y, 1, 1)
	         mipmapLevel:0];

	fprintf(stdout,
	        "probe-source frame=%u eye=%u fmt=%lu texel0=(%u,%u,%u,%u) texelC=(%u,%u,%u,%u)\n",
	        frame_index,
	        view_index,
	        (unsigned long)texture.pixelFormat,
	        (unsigned)texel0[0],
	        (unsigned)texel0[1],
	        (unsigned)texel0[2],
	        (unsigned)texel0[3],
	        (unsigned)texel_center[0],
	        (unsigned)texel_center[1],
	        (unsigned)texel_center[2],
	        (unsigned)texel_center[3]);
}

static int
enumerate_instance_extensions(PFN_xrEnumerateInstanceExtensionProperties xrEnumerateInstanceExtensionProperties,
                              struct instance_extensions *out_exts)
{
	uint32_t count = 0;
	XrResult xr = xrEnumerateInstanceExtensionProperties(NULL, 0, &count, NULL);
	if (xr != XR_SUCCESS) {
		return fail_xr("xrEnumerateInstanceExtensionProperties(count)", xr);
	}

	XrExtensionProperties *exts = calloc(count, sizeof(*exts));
	if (exts == NULL) {
		return fail_msg("calloc(xr extension properties) failed");
	}

	for (uint32_t i = 0; i < count; ++i) {
		exts[i].type = XR_TYPE_EXTENSION_PROPERTIES;
	}

	xr = xrEnumerateInstanceExtensionProperties(NULL, count, &count, exts);
	if (xr != XR_SUCCESS) {
		free(exts);
		return fail_xr("xrEnumerateInstanceExtensionProperties(list)", xr);
	}

	memset(out_exts, 0, sizeof(*out_exts));
	for (uint32_t i = 0; i < count; ++i) {
		if (strcmp(exts[i].extensionName, XR_KHR_METAL_ENABLE_EXTENSION_NAME) == 0) {
			out_exts->metal_enable = true;
		}
	}
	free(exts);

	fprintf(stdout, "Runtime extension XR_KHR_metal_enable: %s\n", out_exts->metal_enable ? "yes" : "no");
	return 0;
}

static int
run_probe_once(uint32_t run_index)
{
	int ret = 1;
	void *runtime = NULL;
	XrInstance instance = XR_NULL_HANDLE;
	XrSession session = XR_NULL_HANDLE;
	XrSpace app_space = XR_NULL_HANDLE;
	XrSessionState current_session_state = XR_SESSION_STATE_UNKNOWN;
	struct probe_swapchain *swapchains = NULL;
	XrViewConfigurationView *view_configs = NULL;
	XrView *views = NULL;
	XrCompositionLayerProjectionView *projection_views = NULL;
	uint32_t view_count = 0;
	uint32_t swapchain_count = 0;
	vector_float3 world_card_positions[4] = {0};
	bool world_card_anchored = false;
	struct probe_world_anchor world_geometry_anchor = {0};
	bool world_geometry_anchored = false;
	id<MTLDevice> metal_device = nil;
	id<MTLCommandQueue> command_queue = nil;
	id<MTLRenderPipelineState> geometry_pipeline = nil;

	const uint32_t frame_limit = get_frame_limit();
	if (frame_limit == 0) {
		return 1;
	}
	const enum probe_pattern pattern = get_probe_pattern();

	const char *runtime_path = getenv("MONADO_OPENXR_RUNTIME_PATH");
	if (runtime_path == NULL || runtime_path[0] == '\0') {
		runtime_path = getenv("WIVRN_OPENXR_RUNTIME_PATH");
	}
	if (runtime_path == NULL || runtime_path[0] == '\0') {
		return fail_msg("Set MONADO_OPENXR_RUNTIME_PATH or WIVRN_OPENXR_RUNTIME_PATH to an OpenXR runtime dylib");
	}

	fprintf(stdout, "=== Metal probe run %u ===\n", run_index);
	fprintf(stdout, "Runtime path: %s\n", runtime_path);
	fprintf(stdout, "Probe pattern: %s\n", probe_pattern_name(pattern));
	fprintf(stdout, "Probe frame limit: %u\n", frame_limit);

	runtime = dlopen(runtime_path, RTLD_NOW | RTLD_LOCAL);
	if (runtime == NULL) {
		fprintf(stderr, "dlopen(%s) failed: %s\n", runtime_path, dlerror());
		goto out;
	}

	PFN_xrNegotiateLoaderRuntimeInterface negotiate =
	    (PFN_xrNegotiateLoaderRuntimeInterface)dlsym(runtime, "xrNegotiateLoaderRuntimeInterface");
	if (negotiate == NULL) {
		fprintf(stderr, "dlsym(xrNegotiateLoaderRuntimeInterface) failed: %s\n", dlerror());
		goto out;
	}

	XrNegotiateLoaderInfo loader_info = {
	    .structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO,
	    .structVersion = XR_LOADER_INFO_STRUCT_VERSION,
	    .structSize = sizeof(loader_info),
	    .minInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION,
	    .maxInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION,
	    .minApiVersion = XR_CURRENT_API_VERSION,
	    .maxApiVersion = XR_CURRENT_API_VERSION,
	};
	XrNegotiateRuntimeRequest runtime_request = {
	    .structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST,
	    .structVersion = XR_RUNTIME_INFO_STRUCT_VERSION,
	    .structSize = sizeof(runtime_request),
	};

	XrResult xr = negotiate(&loader_info, &runtime_request);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrNegotiateLoaderRuntimeInterface", xr);
		goto out;
	}

	PFN_xrGetInstanceProcAddr get_instance_proc_addr = runtime_request.getInstanceProcAddr;
	if (get_instance_proc_addr == NULL) {
		ret = fail_msg("Runtime negotiation returned NULL xrGetInstanceProcAddr");
		goto out;
	}

	PFN_xrEnumerateInstanceExtensionProperties xrEnumerateInstanceExtensionProperties = NULL;
	PFN_xrCreateInstance xrCreateInstance = NULL;
	if (get_proc(get_instance_proc_addr,
	             XR_NULL_HANDLE,
	             "xrEnumerateInstanceExtensionProperties",
	             (PFN_xrVoidFunction *)&xrEnumerateInstanceExtensionProperties) != 0 ||
	    get_proc(get_instance_proc_addr, XR_NULL_HANDLE, "xrCreateInstance", (PFN_xrVoidFunction *)&xrCreateInstance) != 0) {
		goto out;
	}

	struct instance_extensions runtime_exts = {0};
	if (enumerate_instance_extensions(xrEnumerateInstanceExtensionProperties, &runtime_exts) != 0) {
		goto out;
	}

	if (!runtime_exts.metal_enable) {
		ret = fail_msg("first failing stage: runtime does not advertise XR_KHR_metal_enable");
		goto out;
	}

	const char *enabled_xr_extensions[] = {
	    XR_KHR_METAL_ENABLE_EXTENSION_NAME,
	};
	XrInstanceCreateInfo instance_info = {
	    .type = XR_TYPE_INSTANCE_CREATE_INFO,
	    .enabledExtensionCount = 1,
	    .enabledExtensionNames = enabled_xr_extensions,
	};
	snprintf(instance_info.applicationInfo.applicationName,
	         sizeof(instance_info.applicationInfo.applicationName),
	         "%s",
	         "wivrn_openxr_metal_frame_probe");
	snprintf(instance_info.applicationInfo.engineName, sizeof(instance_info.applicationInfo.engineName), "%s", "wivrn-macos");
	instance_info.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;

	xr = xrCreateInstance(&instance_info, &instance);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrCreateInstance", xr);
		goto out;
	}

	PFN_xrDestroyInstance xrDestroyInstance = NULL;
	PFN_xrPollEvent xrPollEvent = NULL;
	PFN_xrGetSystem xrGetSystem = NULL;
	PFN_xrCreateSession xrCreateSession = NULL;
	PFN_xrDestroySession xrDestroySession = NULL;
	PFN_xrBeginSession xrBeginSession = NULL;
	PFN_xrEndSession xrEndSession = NULL;
	PFN_xrWaitFrame xrWaitFrame = NULL;
	PFN_xrBeginFrame xrBeginFrame = NULL;
	PFN_xrEndFrame xrEndFrame = NULL;
	PFN_xrLocateViews xrLocateViews = NULL;
	PFN_xrCreateReferenceSpace xrCreateReferenceSpace = NULL;
	PFN_xrDestroySpace xrDestroySpace = NULL;
	PFN_xrEnumerateViewConfigurationViews xrEnumerateViewConfigurationViews = NULL;
	PFN_xrEnumerateSwapchainFormats xrEnumerateSwapchainFormats = NULL;
	PFN_xrCreateSwapchain xrCreateSwapchain = NULL;
	PFN_xrDestroySwapchain xrDestroySwapchain = NULL;
	PFN_xrEnumerateSwapchainImages xrEnumerateSwapchainImages = NULL;
	PFN_xrAcquireSwapchainImage xrAcquireSwapchainImage = NULL;
	PFN_xrWaitSwapchainImage xrWaitSwapchainImage = NULL;
	PFN_xrReleaseSwapchainImage xrReleaseSwapchainImage = NULL;
	PFN_xrGetMetalGraphicsRequirementsKHR xrGetMetalGraphicsRequirementsKHR = NULL;

	if (get_proc(get_instance_proc_addr, instance, "xrDestroyInstance", (PFN_xrVoidFunction *)&xrDestroyInstance) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrPollEvent", (PFN_xrVoidFunction *)&xrPollEvent) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrGetSystem", (PFN_xrVoidFunction *)&xrGetSystem) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrCreateSession", (PFN_xrVoidFunction *)&xrCreateSession) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrDestroySession", (PFN_xrVoidFunction *)&xrDestroySession) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrBeginSession", (PFN_xrVoidFunction *)&xrBeginSession) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrEndSession", (PFN_xrVoidFunction *)&xrEndSession) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrWaitFrame", (PFN_xrVoidFunction *)&xrWaitFrame) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrBeginFrame", (PFN_xrVoidFunction *)&xrBeginFrame) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrEndFrame", (PFN_xrVoidFunction *)&xrEndFrame) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrLocateViews", (PFN_xrVoidFunction *)&xrLocateViews) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrCreateReferenceSpace",
	             (PFN_xrVoidFunction *)&xrCreateReferenceSpace) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrDestroySpace", (PFN_xrVoidFunction *)&xrDestroySpace) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrEnumerateViewConfigurationViews",
	             (PFN_xrVoidFunction *)&xrEnumerateViewConfigurationViews) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrEnumerateSwapchainFormats",
	             (PFN_xrVoidFunction *)&xrEnumerateSwapchainFormats) != 0 ||
	    get_proc(get_instance_proc_addr, instance, "xrCreateSwapchain", (PFN_xrVoidFunction *)&xrCreateSwapchain) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrDestroySwapchain",
	             (PFN_xrVoidFunction *)&xrDestroySwapchain) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrEnumerateSwapchainImages",
	             (PFN_xrVoidFunction *)&xrEnumerateSwapchainImages) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrAcquireSwapchainImage",
	             (PFN_xrVoidFunction *)&xrAcquireSwapchainImage) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrWaitSwapchainImage",
	             (PFN_xrVoidFunction *)&xrWaitSwapchainImage) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrReleaseSwapchainImage",
	             (PFN_xrVoidFunction *)&xrReleaseSwapchainImage) != 0 ||
	    get_proc(get_instance_proc_addr,
	             instance,
	             "xrGetMetalGraphicsRequirementsKHR",
	             (PFN_xrVoidFunction *)&xrGetMetalGraphicsRequirementsKHR) != 0) {
		goto out;
	}

	XrSystemId system_id = XR_NULL_SYSTEM_ID;
	XrSystemGetInfo system_info = {
	    .type = XR_TYPE_SYSTEM_GET_INFO,
	    .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY,
	};
	xr = xrGetSystem(instance, &system_info, &system_id);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrGetSystem", xr);
		goto out;
	}

	metal_device = MTLCreateSystemDefaultDevice();
	if (metal_device == nil) {
		ret = fail_msg("MTLCreateSystemDefaultDevice returned nil");
		goto out;
	}
	command_queue = [metal_device newCommandQueue];
	if (command_queue == nil) {
		ret = fail_msg("Failed to create Metal command queue");
		goto out;
	}

	XrGraphicsRequirementsMetalKHR graphics_requirements = {
	    .type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR,
	};
	xr = xrGetMetalGraphicsRequirementsKHR(instance, system_id, &graphics_requirements);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrGetMetalGraphicsRequirementsKHR", xr);
		goto out;
	}

	fprintf(stdout, "Metal device: %s\n", metal_device.name.UTF8String);
	fprintf(stdout, "Runtime-required Metal device pointer: %p\n", graphics_requirements.metalDevice);
	fprintf(stdout, "App Metal device pointer: %p\n", (__bridge void *)metal_device);

	XrGraphicsBindingMetalKHR binding = {
	    .type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR,
	    .commandQueue = (__bridge void *)command_queue,
	};
	XrSessionCreateInfo session_info = {
	    .type = XR_TYPE_SESSION_CREATE_INFO,
	    .next = &binding,
	    .systemId = system_id,
	};
	xr = xrCreateSession(instance, &session_info, &session);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrCreateSession", xr);
		goto out;
	}
	fprintf(stdout, "XR session creation: success\n");

	if (wait_for_session_state(xrPollEvent, instance, XR_SESSION_STATE_READY, &current_session_state) != 0) {
		ret = 1;
		goto out;
	}

	XrSessionBeginInfo begin_info = {
	    .type = XR_TYPE_SESSION_BEGIN_INFO,
	    .primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
	};
	xr = xrBeginSession(session, &begin_info);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrBeginSession", xr);
		goto out;
	}

	XrReferenceSpaceCreateInfo space_info = {
	    .type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
	    .referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE,
	    .poseInReferenceSpace.orientation.w = 1.0f,
	};
	xr = xrCreateReferenceSpace(session, &space_info, &app_space);
	if (xr != XR_SUCCESS) {
		space_info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
		xr = xrCreateReferenceSpace(session, &space_info, &app_space);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrCreateReferenceSpace", xr);
			goto out;
		}
	}
	fprintf(stdout, "Reference space: %s\n",
	        space_info.referenceSpaceType == XR_REFERENCE_SPACE_TYPE_STAGE ? "STAGE" : "LOCAL");

	xr = xrEnumerateViewConfigurationViews(
	    instance, system_id, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &view_count, NULL);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrEnumerateViewConfigurationViews(count)", xr);
		goto out;
	}
	fprintf(stdout, "Stereo view count: %u\n", view_count);
	if (view_count != 2) {
		ret = fail_msg("Expected stereo view count=2");
		goto out;
	}

	view_configs = calloc(view_count, sizeof(*view_configs));
	views = calloc(view_count, sizeof(*views));
	projection_views = calloc(view_count, sizeof(*projection_views));
	if (view_configs == NULL || views == NULL || projection_views == NULL) {
		ret = fail_msg("calloc(view data) failed");
		goto out;
	}
	for (uint32_t i = 0; i < view_count; ++i) {
		view_configs[i].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
		views[i].type = XR_TYPE_VIEW;
		projection_views[i].type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
	}

	xr = xrEnumerateViewConfigurationViews(
	    instance, system_id, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, view_count, &view_count, view_configs);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrEnumerateViewConfigurationViews(list)", xr);
		goto out;
	}

	uint32_t format_count = 0;
	xr = xrEnumerateSwapchainFormats(session, 0, &format_count, NULL);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrEnumerateSwapchainFormats(count)", xr);
		goto out;
	}
	int64_t *formats = calloc(format_count, sizeof(*formats));
	if (formats == NULL) {
		ret = fail_msg("calloc(swapchain formats) failed");
		goto out;
	}
	xr = xrEnumerateSwapchainFormats(session, format_count, &format_count, formats);
	if (xr != XR_SUCCESS) {
		free(formats);
		ret = fail_xr("xrEnumerateSwapchainFormats(list)", xr);
		goto out;
	}

	const int64_t chosen_format = choose_swapchain_format(formats, format_count);
	fprintf(stdout, "Swapchain format count: %u\n", format_count);
	fprintf(stdout, "Chosen Metal swapchain format: %lld\n", (long long)chosen_format);
	if (pattern == PROBE_PATTERN_GEOMETRY_CARD || pattern == PROBE_PATTERN_GEOMETRY_QUADRANTS ||
	    pattern == PROBE_PATTERN_WORLD_CARD || pattern == PROBE_PATTERN_WORLD_GRID ||
	    pattern == PROBE_PATTERN_WORLD_GRID_PASSTHROUGH || pattern == PROBE_PATTERN_WORLD_GEOMETRY) {
		geometry_pipeline = create_probe_geometry_pipeline(metal_device, (MTLPixelFormat)chosen_format, pattern);
		if (geometry_pipeline == nil) {
			free(formats);
			ret = fail_msg("Failed to create geometry probe render pipeline");
			goto out;
		}
		fprintf(stdout, "Probe geometry pipeline: ready\n");
	}

	swapchain_count = view_count;
	swapchains = calloc(swapchain_count, sizeof(*swapchains));
	if (swapchains == NULL) {
		free(formats);
		ret = fail_msg("calloc(probe swapchains) failed");
		goto out;
	}

	for (uint32_t i = 0; i < swapchain_count; ++i) {
		swapchains[i].create_info = (XrSwapchainCreateInfo){
		    .type = XR_TYPE_SWAPCHAIN_CREATE_INFO,
		    .usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT,
		    .format = chosen_format,
		    .sampleCount = view_configs[i].recommendedSwapchainSampleCount,
		    .width = view_configs[i].recommendedImageRectWidth,
		    .height = view_configs[i].recommendedImageRectHeight,
		    .faceCount = 1,
		    .arraySize = 1,
		    .mipCount = 1,
		};
		fprintf(stdout,
		        "Swapchain[%u]: %ux%u sampleCount=%u\n",
		        i,
		        swapchains[i].create_info.width,
		        swapchains[i].create_info.height,
		        swapchains[i].create_info.sampleCount);
	}
	free(formats);

	for (uint32_t i = 0; i < swapchain_count; ++i) {
		xr = xrCreateSwapchain(session, &swapchains[i].create_info, &swapchains[i].handle);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrCreateSwapchain", xr);
			goto out;
		}

		xr = xrEnumerateSwapchainImages(swapchains[i].handle, 0, &swapchains[i].image_count, NULL);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrEnumerateSwapchainImages(count)", xr);
			goto out;
		}

		swapchains[i].images = calloc(swapchains[i].image_count, sizeof(*swapchains[i].images));
		if (swapchains[i].images == NULL) {
			ret = fail_msg("calloc(swapchain images) failed");
			goto out;
		}
		for (uint32_t j = 0; j < swapchains[i].image_count; ++j) {
			swapchains[i].images[j].type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR;
		}

		xr = xrEnumerateSwapchainImages(swapchains[i].handle,
		                                swapchains[i].image_count,
		                                &swapchains[i].image_count,
		                                (XrSwapchainImageBaseHeader *)swapchains[i].images);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrEnumerateSwapchainImages(list)", xr);
			goto out;
		}
		fprintf(stdout, "Swapchain[%u] image count: %u\n", i, swapchains[i].image_count);
	}

	uint32_t submitted_frames = 0;
	bool logged_wait_frame = false;
	bool logged_begin_frame = false;
	bool logged_acquire = false;
	bool logged_submit = false;
	bool logged_probe_source = false;

	while (submitted_frames < frame_limit) {
		XrFrameWaitInfo frame_wait_info = {
		    .type = XR_TYPE_FRAME_WAIT_INFO,
		};
		XrFrameState frame_state = {
		    .type = XR_TYPE_FRAME_STATE,
		};
		xr = xrWaitFrame(session, &frame_wait_info, &frame_state);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrWaitFrame", xr);
			goto out;
		}
		if (!logged_wait_frame) {
			fprintf(stdout, "First successful frame wait at predicted display time=%lld\n",
			        (long long)frame_state.predictedDisplayTime);
			logged_wait_frame = true;
		}

		XrFrameBeginInfo frame_begin_info = {
		    .type = XR_TYPE_FRAME_BEGIN_INFO,
		};
		xr = xrBeginFrame(session, &frame_begin_info);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrBeginFrame", xr);
			goto out;
		}
		if (!logged_begin_frame) {
			fprintf(stdout, "First successful frame begin\n");
			logged_begin_frame = true;
		}

		XrViewLocateInfo locate_info = {
		    .type = XR_TYPE_VIEW_LOCATE_INFO,
		    .viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
		    .displayTime = frame_state.predictedDisplayTime,
		    .space = app_space,
		};
		XrViewState view_state = {
		    .type = XR_TYPE_VIEW_STATE,
		};
		uint32_t located_view_count = 0;
		xr = xrLocateViews(session, &locate_info, &view_state, view_count, &located_view_count, views);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrLocateViews", xr);
			goto out;
		}
		if (located_view_count != view_count) {
			ret = fail_msg("xrLocateViews returned unexpected view count");
			goto out;
		}
		if ((pattern == PROBE_PATTERN_WORLD_CARD || pattern == PROBE_PATTERN_WORLD_GRID ||
		     pattern == PROBE_PATTERN_WORLD_GRID_PASSTHROUGH) && !world_card_anchored) {
			if (pattern == PROBE_PATTERN_WORLD_GRID || pattern == PROBE_PATTERN_WORLD_GRID_PASSTHROUGH) {
				anchor_world_grid_from_views(views, world_card_positions);
			} else {
				anchor_world_card_from_views(views, world_card_positions);
			}
			world_card_anchored = true;
			fprintf(stdout,
			        "Anchored world-card at corners: "
			        "(%.3f,%.3f,%.3f) (%.3f,%.3f,%.3f) (%.3f,%.3f,%.3f) (%.3f,%.3f,%.3f)\n",
			        world_card_positions[0].x,
			        world_card_positions[0].y,
			        world_card_positions[0].z,
			        world_card_positions[1].x,
			        world_card_positions[1].y,
			        world_card_positions[1].z,
			        world_card_positions[2].x,
			        world_card_positions[2].y,
			        world_card_positions[2].z,
			        world_card_positions[3].x,
			        world_card_positions[3].y,
			        world_card_positions[3].z);
		}
		if (pattern == PROBE_PATTERN_WORLD_GEOMETRY && !world_geometry_anchored) {
			anchor_world_geometry_from_views(views, &world_geometry_anchor);
			world_geometry_anchored = true;
			fprintf(stdout,
			        "Anchored world-geometry center=(%.3f,%.3f,%.3f) distance=%.3f "
			        "right=(%.3f,%.3f,%.3f) up=(%.3f,%.3f,%.3f)\n",
			        world_geometry_anchor.center.x,
			        world_geometry_anchor.center.y,
			        world_geometry_anchor.center.z,
			        world_geometry_anchor.distance,
			        world_geometry_anchor.right.x,
			        world_geometry_anchor.right.y,
			        world_geometry_anchor.right.z,
			        world_geometry_anchor.up.x,
			        world_geometry_anchor.up.y,
			        world_geometry_anchor.up.z);
		}

		for (uint32_t i = 0; i < swapchain_count; ++i) {
			uint32_t image_index = 0;
			XrSwapchainImageAcquireInfo acquire_info = {
			    .type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO,
			};
			xr = xrAcquireSwapchainImage(swapchains[i].handle, &acquire_info, &image_index);
			if (xr != XR_SUCCESS) {
				ret = fail_xr("xrAcquireSwapchainImage", xr);
				goto out;
			}

			XrSwapchainImageWaitInfo wait_info = {
			    .type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO,
			    .timeout = XR_INFINITE_DURATION,
			};
			xr = xrWaitSwapchainImage(swapchains[i].handle, &wait_info);
			if (xr != XR_SUCCESS) {
				ret = fail_xr("xrWaitSwapchainImage", xr);
				goto out;
			}
			if (!logged_acquire) {
				fprintf(stdout, "First successful image acquire/wait on view %u image %u\n", i, image_index);
				logged_acquire = true;
			}

			if (render_pattern_to_swapchain_image(command_queue,
			                                     geometry_pipeline,
			                                     &swapchains[i].images[image_index],
			                                     pattern,
			                                     &views[i],
			                                     world_geometry_anchored ? &world_geometry_anchor : NULL,
			                                     world_card_positions,
			                                     i,
			                                     submitted_frames) != 0) {
				ret = fail_msg("Metal render failed");
				goto out;
			}
			if (!logged_probe_source || submitted_frames == frame_limit - 1) {
				log_swapchain_image_sample(&swapchains[i].images[image_index], i, submitted_frames);
			}

			XrSwapchainImageReleaseInfo release_info = {
			    .type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO,
			};
			xr = xrReleaseSwapchainImage(swapchains[i].handle, &release_info);
			if (xr != XR_SUCCESS) {
				ret = fail_xr("xrReleaseSwapchainImage", xr);
				goto out;
			}
		}

		for (uint32_t i = 0; i < view_count; ++i) {
			projection_views[i].pose = views[i].pose;
			projection_views[i].fov = views[i].fov;
			projection_views[i].subImage.swapchain = swapchains[i].handle;
			projection_views[i].subImage.imageRect.offset.x = 0;
			projection_views[i].subImage.imageRect.offset.y = 0;
			projection_views[i].subImage.imageRect.extent.width = (int32_t)swapchains[i].create_info.width;
			projection_views[i].subImage.imageRect.extent.height = (int32_t)swapchains[i].create_info.height;
			projection_views[i].subImage.imageArrayIndex = 0;
		}

		const bool use_passthrough = (pattern == PROBE_PATTERN_WORLD_GRID_PASSTHROUGH ||
		                              pattern == PROBE_PATTERN_SOLID_WHITE_PASSTHROUGH);
		XrCompositionLayerProjection layer = {
		    .type = XR_TYPE_COMPOSITION_LAYER_PROJECTION,
		    .layerFlags = use_passthrough ? XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT : 0,
		    .space = app_space,
		    .viewCount = view_count,
		    .views = projection_views,
		};
		const XrCompositionLayerBaseHeader *layers[] = {
		    (const XrCompositionLayerBaseHeader *)&layer,
		};
		XrFrameEndInfo frame_end_info = {
		    .type = XR_TYPE_FRAME_END_INFO,
		    .displayTime = frame_state.predictedDisplayTime,
		    .environmentBlendMode = use_passthrough
		        ? XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND
		        : XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
		    .layerCount = 1,
		    .layers = layers,
		};
		xr = xrEndFrame(session, &frame_end_info);
		if (xr != XR_SUCCESS) {
			ret = fail_xr("xrEndFrame", xr);
			goto out;
		}
		if (!logged_submit) {
			fprintf(stdout, "First successful frame submit\n");
			logged_submit = true;
		}
		logged_probe_source = true;

		submitted_frames++;
	}

	fprintf(stdout, "Total submitted frame count before exit: %u\n", submitted_frames);
	ret = 0;

out:
	if (session != XR_NULL_HANDLE) {
		if (xrEndSession != NULL && current_session_state == XR_SESSION_STATE_STOPPING) {
			XrResult end_result = xrEndSession(session);
			if (end_result != XR_SUCCESS) {
				fprintf(stderr, "xrEndSession failed during shutdown: %d\n", end_result);
			}
		}
	}
	if (swapchains != NULL) {
		for (uint32_t i = 0; i < swapchain_count; ++i) {
			free(swapchains[i].images);
			if (swapchains[i].handle != XR_NULL_HANDLE) {
				PFN_xrDestroySwapchain destroy_swapchain = NULL;
				if (instance != XR_NULL_HANDLE &&
				    get_proc(((PFN_xrGetInstanceProcAddr)runtime_request.getInstanceProcAddr),
				             instance,
				             "xrDestroySwapchain",
				             (PFN_xrVoidFunction *)&destroy_swapchain) == 0 &&
				    destroy_swapchain != NULL) {
					destroy_swapchain(swapchains[i].handle);
				}
			}
		}
		free(swapchains);
	}
	free(projection_views);
	free(views);
	free(view_configs);
	if (app_space != XR_NULL_HANDLE) {
		PFN_xrDestroySpace xrDestroySpace = NULL;
		if (instance != XR_NULL_HANDLE &&
		    get_proc(((PFN_xrGetInstanceProcAddr)runtime_request.getInstanceProcAddr),
		             instance,
		             "xrDestroySpace",
		             (PFN_xrVoidFunction *)&xrDestroySpace) == 0 &&
		    xrDestroySpace != NULL) {
			xrDestroySpace(app_space);
		}
	}
	if (session != XR_NULL_HANDLE) {
		PFN_xrDestroySession xrDestroySession = NULL;
		if (instance != XR_NULL_HANDLE &&
		    get_proc(((PFN_xrGetInstanceProcAddr)runtime_request.getInstanceProcAddr),
		             instance,
		             "xrDestroySession",
		             (PFN_xrVoidFunction *)&xrDestroySession) == 0 &&
		    xrDestroySession != NULL) {
			xrDestroySession(session);
		}
	}
	if (instance != XR_NULL_HANDLE) {
		PFN_xrDestroyInstance xrDestroyInstance = NULL;
		if (get_proc(((PFN_xrGetInstanceProcAddr)runtime_request.getInstanceProcAddr),
		             instance,
		             "xrDestroyInstance",
		             (PFN_xrVoidFunction *)&xrDestroyInstance) == 0 &&
		    xrDestroyInstance != NULL) {
			xrDestroyInstance(instance);
		}
	}
	if (runtime != NULL) {
		dlclose(runtime);
	}

	return ret;
}

int
main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	setvbuf(stdout, NULL, _IOLBF, 0);

	@autoreleasepool {
		if (run_probe_once(1) != 0) {
			return 1;
		}

		fprintf(stdout, "First run shut down cleanly; repeating once.\n");
		if (run_probe_once(2) != 0) {
			return 1;
		}
	}

	return 0;
}
