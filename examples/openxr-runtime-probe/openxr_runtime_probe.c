// Copyright 2026
// SPDX-License-Identifier: BSL-1.0

#define XR_USE_GRAPHICS_API_METAL 1

#include <dlfcn.h>
#include <inttypes.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "openxr/openxr.h"
#include "openxr/openxr_platform.h"

struct openxr_loader
{
	void *handle;
	char path[1024];
	PFN_xrGetInstanceProcAddr xrGetInstanceProcAddr;
};

static const char *
result_name(XrResult result)
{
	switch (result) {
	case XR_SUCCESS: return "XR_SUCCESS";
	case XR_TIMEOUT_EXPIRED: return "XR_TIMEOUT_EXPIRED";
	case XR_SESSION_LOSS_PENDING: return "XR_SESSION_LOSS_PENDING";
	case XR_EVENT_UNAVAILABLE: return "XR_EVENT_UNAVAILABLE";
	case XR_SPACE_BOUNDS_UNAVAILABLE: return "XR_SPACE_BOUNDS_UNAVAILABLE";
	case XR_SESSION_NOT_FOCUSED: return "XR_SESSION_NOT_FOCUSED";
	case XR_FRAME_DISCARDED: return "XR_FRAME_DISCARDED";
	case XR_ERROR_VALIDATION_FAILURE: return "XR_ERROR_VALIDATION_FAILURE";
	case XR_ERROR_RUNTIME_FAILURE: return "XR_ERROR_RUNTIME_FAILURE";
	case XR_ERROR_OUT_OF_MEMORY: return "XR_ERROR_OUT_OF_MEMORY";
	case XR_ERROR_API_VERSION_UNSUPPORTED: return "XR_ERROR_API_VERSION_UNSUPPORTED";
	case XR_ERROR_INITIALIZATION_FAILED: return "XR_ERROR_INITIALIZATION_FAILED";
	case XR_ERROR_FUNCTION_UNSUPPORTED: return "XR_ERROR_FUNCTION_UNSUPPORTED";
	case XR_ERROR_FEATURE_UNSUPPORTED: return "XR_ERROR_FEATURE_UNSUPPORTED";
	case XR_ERROR_EXTENSION_NOT_PRESENT: return "XR_ERROR_EXTENSION_NOT_PRESENT";
	case XR_ERROR_LIMIT_REACHED: return "XR_ERROR_LIMIT_REACHED";
	case XR_ERROR_RUNTIME_UNAVAILABLE: return "XR_ERROR_RUNTIME_UNAVAILABLE";
	case XR_ERROR_SIZE_INSUFFICIENT: return "XR_ERROR_SIZE_INSUFFICIENT";
	case XR_ERROR_HANDLE_INVALID: return "XR_ERROR_HANDLE_INVALID";
	case XR_ERROR_INSTANCE_LOST: return "XR_ERROR_INSTANCE_LOST";
	case XR_ERROR_SESSION_RUNNING: return "XR_ERROR_SESSION_RUNNING";
	case XR_ERROR_SESSION_NOT_RUNNING: return "XR_ERROR_SESSION_NOT_RUNNING";
	case XR_ERROR_SESSION_LOST: return "XR_ERROR_SESSION_LOST";
	case XR_ERROR_SYSTEM_INVALID: return "XR_ERROR_SYSTEM_INVALID";
	case XR_ERROR_PATH_INVALID: return "XR_ERROR_PATH_INVALID";
	case XR_ERROR_PATH_COUNT_EXCEEDED: return "XR_ERROR_PATH_COUNT_EXCEEDED";
	case XR_ERROR_PATH_FORMAT_INVALID: return "XR_ERROR_PATH_FORMAT_INVALID";
	case XR_ERROR_PATH_UNSUPPORTED: return "XR_ERROR_PATH_UNSUPPORTED";
	case XR_ERROR_LAYER_INVALID: return "XR_ERROR_LAYER_INVALID";
	case XR_ERROR_LAYER_LIMIT_EXCEEDED: return "XR_ERROR_LAYER_LIMIT_EXCEEDED";
	case XR_ERROR_SWAPCHAIN_RECT_INVALID: return "XR_ERROR_SWAPCHAIN_RECT_INVALID";
	case XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED: return "XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED";
	case XR_ERROR_ACTION_TYPE_MISMATCH: return "XR_ERROR_ACTION_TYPE_MISMATCH";
	case XR_ERROR_SESSION_NOT_READY: return "XR_ERROR_SESSION_NOT_READY";
	case XR_ERROR_SESSION_NOT_STOPPING: return "XR_ERROR_SESSION_NOT_STOPPING";
	case XR_ERROR_TIME_INVALID: return "XR_ERROR_TIME_INVALID";
	case XR_ERROR_REFERENCE_SPACE_UNSUPPORTED: return "XR_ERROR_REFERENCE_SPACE_UNSUPPORTED";
	case XR_ERROR_FILE_ACCESS_ERROR: return "XR_ERROR_FILE_ACCESS_ERROR";
	case XR_ERROR_FILE_CONTENTS_INVALID: return "XR_ERROR_FILE_CONTENTS_INVALID";
	case XR_ERROR_FORM_FACTOR_UNSUPPORTED: return "XR_ERROR_FORM_FACTOR_UNSUPPORTED";
	case XR_ERROR_FORM_FACTOR_UNAVAILABLE: return "XR_ERROR_FORM_FACTOR_UNAVAILABLE";
	case XR_ERROR_API_LAYER_NOT_PRESENT: return "XR_ERROR_API_LAYER_NOT_PRESENT";
	case XR_ERROR_CALL_ORDER_INVALID: return "XR_ERROR_CALL_ORDER_INVALID";
	case XR_ERROR_GRAPHICS_DEVICE_INVALID: return "XR_ERROR_GRAPHICS_DEVICE_INVALID";
	case XR_ERROR_POSE_INVALID: return "XR_ERROR_POSE_INVALID";
	case XR_ERROR_INDEX_OUT_OF_RANGE: return "XR_ERROR_INDEX_OUT_OF_RANGE";
	case XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED: return "XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED";
	case XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED: return "XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED";
	case XR_ERROR_NAME_DUPLICATED: return "XR_ERROR_NAME_DUPLICATED";
	case XR_ERROR_NAME_INVALID: return "XR_ERROR_NAME_INVALID";
	case XR_ERROR_ACTIONSET_NOT_ATTACHED: return "XR_ERROR_ACTIONSET_NOT_ATTACHED";
	case XR_ERROR_ACTIONSETS_ALREADY_ATTACHED: return "XR_ERROR_ACTIONSETS_ALREADY_ATTACHED";
	case XR_ERROR_LOCALIZED_NAME_DUPLICATED: return "XR_ERROR_LOCALIZED_NAME_DUPLICATED";
	case XR_ERROR_LOCALIZED_NAME_INVALID: return "XR_ERROR_LOCALIZED_NAME_INVALID";
	default: return "XR_RESULT_UNKNOWN";
	}
}

static int
fail_xr(const char *what, XrResult result)
{
	fprintf(stderr, "%s failed: %s (%d)\n", what, result_name(result), result);
	return 1;
}

static bool
try_load_path(const char *path, struct openxr_loader *out_loader)
{
	if (path == NULL || path[0] == '\0') {
		return false;
	}

	void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (handle == NULL) {
		return false;
	}

	PFN_xrGetInstanceProcAddr get_instance_proc_addr =
	    (PFN_xrGetInstanceProcAddr)dlsym(handle, "xrGetInstanceProcAddr");
	if (get_instance_proc_addr == NULL) {
		fprintf(stderr, "%s does not export xrGetInstanceProcAddr\n", path);
		dlclose(handle);
		return false;
	}

	out_loader->handle = handle;
	snprintf(out_loader->path, sizeof(out_loader->path), "%s", path);
	out_loader->xrGetInstanceProcAddr = get_instance_proc_addr;
	return true;
}

static bool
get_executable_dir(char *out_dir, size_t out_dir_size)
{
	char exe_path[PATH_MAX];
	uint32_t exe_path_size = sizeof(exe_path);
	if (_NSGetExecutablePath(exe_path, &exe_path_size) != 0) {
		return false;
	}

	char resolved_path[PATH_MAX];
	const char *path = realpath(exe_path, resolved_path);
	if (path == NULL) {
		path = exe_path;
	}

	if (snprintf(out_dir, out_dir_size, "%s", path) >= (int)out_dir_size) {
		return false;
	}

	char *last_slash = strrchr(out_dir, '/');
	if (last_slash == NULL) {
		return false;
	}
	*last_slash = '\0';
	return true;
}

static bool
try_load_executable_relative(const char *relative_path, struct openxr_loader *out_loader)
{
	char exe_dir[PATH_MAX];
	if (!get_executable_dir(exe_dir, sizeof(exe_dir))) {
		return false;
	}

	char candidate[PATH_MAX];
	if (snprintf(candidate, sizeof(candidate), "%s/%s", exe_dir, relative_path) >= (int)sizeof(candidate)) {
		return false;
	}

	return try_load_path(candidate, out_loader);
}

static int
load_openxr_loader(struct openxr_loader *out_loader)
{
	memset(out_loader, 0, sizeof(*out_loader));

	const char *env_path = getenv("WIVRN_OPENXR_LOADER_PATH");
	if (env_path != NULL && env_path[0] != '\0') {
		if (!try_load_path(env_path, out_loader)) {
			fprintf(stderr, "Failed to load WIVRN_OPENXR_LOADER_PATH=%s: %s\n", env_path, dlerror());
			return 1;
		}
		return 0;
	}

	env_path = getenv("OPENXR_LOADER_DYLIB");
	if (env_path != NULL && env_path[0] != '\0') {
		if (!try_load_path(env_path, out_loader)) {
			fprintf(stderr, "Failed to load OPENXR_LOADER_DYLIB=%s: %s\n", env_path, dlerror());
			return 1;
		}
		return 0;
	}

	const char *relative_paths[] = {
	    "../openxr-loader/lib/libopenxr_loader.dylib",
	    "../Frameworks/libopenxr_loader.dylib",
	    "../Resources/openxr/libopenxr_loader.dylib",
	    "libopenxr_loader.dylib",
	};
	for (size_t i = 0; i < sizeof(relative_paths) / sizeof(relative_paths[0]); ++i) {
		if (try_load_executable_relative(relative_paths[i], out_loader)) {
			return 0;
		}
	}

	const char *paths[] = {
	    "libopenxr_loader.dylib",
	    "/opt/homebrew/lib/libopenxr_loader.dylib",
	    "/usr/local/lib/libopenxr_loader.dylib",
	    "/usr/lib/libopenxr_loader.dylib",
	};
	for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i) {
		if (try_load_path(paths[i], out_loader)) {
			return 0;
		}
	}

	fprintf(stderr, "Could not load libopenxr_loader.dylib.\n");
	fprintf(stderr, "Run scripts/build_openxr_loader.sh or set WIVRN_OPENXR_LOADER_PATH.\n");
	return 1;
}

static int
get_proc(PFN_xrGetInstanceProcAddr get_instance_proc_addr,
         XrInstance instance,
         const char *name,
         PFN_xrVoidFunction *out_fn)
{
	XrResult xr = get_instance_proc_addr(instance, name, out_fn);
	if (xr != XR_SUCCESS) {
		return fail_xr(name, xr);
	}
	if (*out_fn == NULL) {
		fprintf(stderr, "%s returned NULL\n", name);
		return 1;
	}
	return 0;
}

static bool
env_truthy(const char *name)
{
	const char *value = getenv(name);
	return value != NULL && value[0] != '\0' && strcmp(value, "0") != 0;
}

int
main(int argc, char **argv)
{
	(void)argc;
	(void)argv;

	setvbuf(stdout, NULL, _IOLBF, 0);

	struct openxr_loader loader = {0};
	if (load_openxr_loader(&loader) != 0) {
		return 1;
	}

	const char *runtime_json = getenv("XR_RUNTIME_JSON");
	fprintf(stdout, "OpenXR loader: %s\n", loader.path);
	fprintf(stdout, "XR_RUNTIME_JSON: %s\n", runtime_json != NULL && runtime_json[0] != '\0' ? runtime_json : "(not set)");

	PFN_xrEnumerateInstanceExtensionProperties xrEnumerateInstanceExtensionProperties = NULL;
	PFN_xrCreateInstance xrCreateInstance = NULL;
	if (get_proc(loader.xrGetInstanceProcAddr,
	             XR_NULL_HANDLE,
	             "xrEnumerateInstanceExtensionProperties",
	             (PFN_xrVoidFunction *)&xrEnumerateInstanceExtensionProperties) != 0 ||
	    get_proc(loader.xrGetInstanceProcAddr,
	             XR_NULL_HANDLE,
	             "xrCreateInstance",
	             (PFN_xrVoidFunction *)&xrCreateInstance) != 0) {
		dlclose(loader.handle);
		return 1;
	}

	uint32_t extension_count = 0;
	XrResult xr = xrEnumerateInstanceExtensionProperties(NULL, 0, &extension_count, NULL);
	if (xr != XR_SUCCESS) {
		dlclose(loader.handle);
		return fail_xr("xrEnumerateInstanceExtensionProperties(count)", xr);
	}

	XrExtensionProperties *extensions = calloc(extension_count, sizeof(*extensions));
	if (extensions == NULL) {
		fprintf(stderr, "calloc(extension properties) failed\n");
		dlclose(loader.handle);
		return 1;
	}
	for (uint32_t i = 0; i < extension_count; ++i) {
		extensions[i].type = XR_TYPE_EXTENSION_PROPERTIES;
	}

	xr = xrEnumerateInstanceExtensionProperties(NULL, extension_count, &extension_count, extensions);
	if (xr != XR_SUCCESS) {
		free(extensions);
		dlclose(loader.handle);
		return fail_xr("xrEnumerateInstanceExtensionProperties(list)", xr);
	}

	bool has_metal = false;
	fprintf(stdout, "Runtime extension count: %u\n", extension_count);
	for (uint32_t i = 0; i < extension_count; ++i) {
		if (strcmp(extensions[i].extensionName, XR_KHR_METAL_ENABLE_EXTENSION_NAME) == 0) {
			has_metal = true;
		}
		if (env_truthy("WIVRN_OPENXR_RUNTIME_PROBE_VERBOSE")) {
			fprintf(stdout, "  %s v%u\n", extensions[i].extensionName, extensions[i].extensionVersion);
		}
	}
	free(extensions);
	fprintf(stdout, "Runtime extension XR_KHR_metal_enable: %s\n", has_metal ? "yes" : "no");

	XrInstance instance = XR_NULL_HANDLE;
	XrInstanceCreateInfo instance_info = {
	    .type = XR_TYPE_INSTANCE_CREATE_INFO,
	};
	snprintf(instance_info.applicationInfo.applicationName,
	         sizeof(instance_info.applicationInfo.applicationName),
	         "%s",
	         "wivrn_openxr_runtime_probe");
	snprintf(instance_info.applicationInfo.engineName,
	         sizeof(instance_info.applicationInfo.engineName),
	         "%s",
	         "wivrn-macos");
	instance_info.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);

	xr = xrCreateInstance(&instance_info, &instance);
	if (xr != XR_SUCCESS) {
		dlclose(loader.handle);
		return fail_xr("xrCreateInstance", xr);
	}
	fprintf(stdout, "OpenXR instance: created\n");

	PFN_xrDestroyInstance xrDestroyInstance = NULL;
	PFN_xrGetSystem xrGetSystem = NULL;
	PFN_xrGetSystemProperties xrGetSystemProperties = NULL;
	PFN_xrEnumerateViewConfigurationViews xrEnumerateViewConfigurationViews = NULL;
	int ret = 1;

	if (get_proc(loader.xrGetInstanceProcAddr,
	             instance,
	             "xrDestroyInstance",
	             (PFN_xrVoidFunction *)&xrDestroyInstance) != 0 ||
	    get_proc(loader.xrGetInstanceProcAddr, instance, "xrGetSystem", (PFN_xrVoidFunction *)&xrGetSystem) != 0 ||
	    get_proc(loader.xrGetInstanceProcAddr,
	             instance,
	             "xrGetSystemProperties",
	             (PFN_xrVoidFunction *)&xrGetSystemProperties) != 0 ||
	    get_proc(loader.xrGetInstanceProcAddr,
	             instance,
	             "xrEnumerateViewConfigurationViews",
	             (PFN_xrVoidFunction *)&xrEnumerateViewConfigurationViews) != 0) {
		goto out;
	}

	XrSystemId system_id = XR_NULL_SYSTEM_ID;
	XrSystemGetInfo system_info = {
	    .type = XR_TYPE_SYSTEM_GET_INFO,
	    .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY,
	};
	xr = xrGetSystem(instance, &system_info, &system_id);
	if (xr != XR_SUCCESS) {
		fprintf(stderr, "xrGetSystem(HMD) failed: %s (%d)\n", result_name(xr), xr);
		if (xr == XR_ERROR_FORM_FACTOR_UNAVAILABLE && env_truthy("WIVRN_OPENXR_RUNTIME_PROBE_ALLOW_UNAVAILABLE")) {
			fprintf(stdout, "No HMD system is currently available; treating as success because allow-unavailable is set.\n");
			ret = 0;
		}
		goto out;
	}

	XrSystemProperties properties = {
	    .type = XR_TYPE_SYSTEM_PROPERTIES,
	};
	xr = xrGetSystemProperties(instance, system_id, &properties);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrGetSystemProperties", xr);
		goto out;
	}

	fprintf(stdout, "OpenXR HMD system: %" PRIu64 "\n", (uint64_t)system_id);
	fprintf(stdout, "System name: %s\n", properties.systemName);
	fprintf(stdout, "Vendor ID: %u\n", properties.vendorId);
	fprintf(stdout,
	        "Max layers: %u, max swapchain size: %ux%u\n",
	        properties.graphicsProperties.maxLayerCount,
	        properties.graphicsProperties.maxSwapchainImageWidth,
	        properties.graphicsProperties.maxSwapchainImageHeight);

	uint32_t view_count = 0;
	xr = xrEnumerateViewConfigurationViews(
	    instance, system_id, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &view_count, NULL);
	if (xr != XR_SUCCESS) {
		ret = fail_xr("xrEnumerateViewConfigurationViews(count)", xr);
		goto out;
	}

	XrViewConfigurationView *views = calloc(view_count, sizeof(*views));
	if (views == NULL) {
		fprintf(stderr, "calloc(view configuration views) failed\n");
		goto out;
	}
	for (uint32_t i = 0; i < view_count; ++i) {
		views[i].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
	}

	xr = xrEnumerateViewConfigurationViews(
	    instance, system_id, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, view_count, &view_count, views);
	if (xr != XR_SUCCESS) {
		free(views);
		ret = fail_xr("xrEnumerateViewConfigurationViews(list)", xr);
		goto out;
	}

	fprintf(stdout, "PRIMARY_STEREO view count: %u\n", view_count);
	for (uint32_t i = 0; i < view_count; ++i) {
		fprintf(stdout,
		        "  view[%u]: recommended=%ux%u max=%ux%u sampleCount=%u\n",
		        i,
		        views[i].recommendedImageRectWidth,
		        views[i].recommendedImageRectHeight,
		        views[i].maxImageRectWidth,
		        views[i].maxImageRectHeight,
		        views[i].recommendedSwapchainSampleCount);
	}
	free(views);

	ret = 0;

out:
	if (instance != XR_NULL_HANDLE && xrDestroyInstance != NULL) {
		XrResult destroy_result = xrDestroyInstance(instance);
		if (destroy_result != XR_SUCCESS) {
			fprintf(stderr, "xrDestroyInstance failed: %s (%d)\n", result_name(destroy_result), destroy_result);
		}
	}
	if (loader.handle != NULL) {
		dlclose(loader.handle);
	}
	return ret;
}
