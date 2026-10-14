// A minimal GDExtension (plain C interface, no godot-cpp) that asks Godot's OpenXR instance for the
// layer extensions neither Godot nor the vendors plugin requests. Extensions are only enabled when the
// instance is created, at the SERVERS level: the wrapper registers itself at CORE, before that.
// Desktop editors load the same entry as an empty stub (no OpenXR runtime, nothing to request).
#include <cstdint>
#include <cstring>
#include "gdextension_interface.h"
#include "layer_extensions.h"

#ifdef _WIN32
#define THRU3D_EXPORT __declspec(dllexport)
#else
#define THRU3D_EXPORT __attribute__((visibility("default")))
#endif

namespace {

// Opaque engine values (64-bit builds): StringName/String 8 bytes, Variant 24.
struct Name { uint8_t data[8]; };
struct Text { uint8_t data[8]; };
struct Value { uint8_t data[24]; };

constexpr const char* kColorScaleBias = "XR_KHR_composition_layer_color_scale_bias";
// OpenXRExtensionWrapper.register_extension_wrapper() in Godot 4.7's extension API.
constexpr GDExtensionInt kRegisterHash = 3218959716;

bool color_scale_bias = false; // written by Godot when it creates the instance

GDExtensionClassLibraryPtr library = nullptr;
GDExtensionInterfaceStringNameNewWithLatin1Chars string_name_new = nullptr;
GDExtensionInterfaceStringNewWithUtf8Chars string_new = nullptr;
GDExtensionInterfaceGetVariantFromTypeConstructor variant_from_type = nullptr;
GDExtensionInterfaceVariantNewCopy variant_copy = nullptr;
GDExtensionInterfaceVariantDestroy variant_destroy = nullptr;
GDExtensionInterfaceVariantGetPtrDestructor destructor = nullptr;
GDExtensionInterfaceDictionaryOperatorIndex dictionary_index = nullptr;
GDExtensionInterfaceClassdbConstructObject2 construct_object = nullptr;
GDExtensionInterfaceObjectSetInstance set_instance = nullptr;
GDExtensionInterfaceClassdbGetMethodBind method_bind = nullptr;
GDExtensionInterfaceObjectMethodBindPtrcall ptrcall = nullptr;
GDExtensionInterfaceClassdbRegisterExtensionClass4 register_class = nullptr;

Name class_name{};
Name parent_name{};
Name requested_name{};
int instance_tag = 0; // the extension instance: the class keeps no per-object state

Name name(const char* text) {
    Name result{};
    string_name_new(&result, text, true);
    return result;
}

GDExtensionObjectPtr create_instance(void*, GDExtensionBool) {
    GDExtensionObjectPtr object = construct_object(&parent_name);
    set_instance(object, &class_name, &instance_tag);
    return object;
}

void free_instance(void*, GDExtensionClassInstancePtr) {}

void* virtual_data(void*, GDExtensionConstStringNamePtr method, uint32_t) {
    // StringNames are interned: the same text shares one pointer.
    return std::memcmp(method, &requested_name, sizeof(Name)) == 0 ? &requested_name : nullptr;
}

// _get_requested_extensions(xr_version) -> Dictionary {name: pointer to the bool Godot sets}.
void call_virtual(GDExtensionClassInstancePtr, GDExtensionConstStringNamePtr, void*, const GDExtensionConstTypePtr*, GDExtensionTypePtr result) {
    Text text{};
    string_new(&text, kColorScaleBias);
    Value key{};
    variant_from_type(GDEXTENSION_VARIANT_TYPE_STRING)(&key, &text);
    destructor(GDEXTENSION_VARIANT_TYPE_STRING)(&text);
    int64_t address = static_cast<int64_t>(reinterpret_cast<uintptr_t>(&color_scale_bias));
    Value pointer{};
    variant_from_type(GDEXTENSION_VARIANT_TYPE_INT)(&pointer, &address);
    GDExtensionVariantPtr slot = dictionary_index(result, &key);
    variant_destroy(slot);
    variant_copy(slot, &pointer);
    variant_destroy(&pointer);
    variant_destroy(&key);
}

void initialize(void*, GDExtensionInitializationLevel level) {
#ifndef __ANDROID__
    (void)level;
    return;
#endif
    if (level != GDEXTENSION_INITIALIZATION_CORE) return;
    class_name = name("Thru3DLayerExtensions");
    parent_name = name("OpenXRExtensionWrapper");
    requested_name = name("_get_requested_extensions");
    GDExtensionClassCreationInfo4 info{};
    info.is_exposed = false;
    info.create_instance_func = create_instance;
    info.free_instance_func = free_instance;
    info.get_virtual_call_data_func = virtual_data;
    info.call_virtual_with_data_func = call_virtual;
    register_class(library, &class_name, &parent_name, &info);
    // One wrapper for the application's lifetime; OpenXR keeps its pointer.
    GDExtensionObjectPtr wrapper = construct_object(&class_name);
    Name method = name("register_extension_wrapper");
    GDExtensionMethodBindPtr bind = method_bind(&parent_name, &method, kRegisterHash);
    if (wrapper && bind) ptrcall(bind, wrapper, nullptr, nullptr);
}

void deinitialize(void*, GDExtensionInitializationLevel) {}

template <typename T>
bool load(GDExtensionInterfaceGetProcAddress get, T& function, const char* symbol) {
    function = reinterpret_cast<T>(get(symbol));
    return function != nullptr;
}

} // namespace

bool thru3d_color_scale_bias_enabled() { return color_scale_bias; }

extern "C" THRU3D_EXPORT GDExtensionBool thru3d_layer_extensions_init(GDExtensionInterfaceGetProcAddress get,
        GDExtensionClassLibraryPtr p_library, GDExtensionInitialization* initialization) {
    library = p_library;
    const bool loaded = load(get, string_name_new, "string_name_new_with_latin1_chars")
        && load(get, string_new, "string_new_with_utf8_chars")
        && load(get, variant_from_type, "get_variant_from_type_constructor")
        && load(get, variant_copy, "variant_new_copy")
        && load(get, variant_destroy, "variant_destroy")
        && load(get, destructor, "variant_get_ptr_destructor")
        && load(get, dictionary_index, "dictionary_operator_index")
        && load(get, construct_object, "classdb_construct_object2")
        && load(get, set_instance, "object_set_instance")
        && load(get, method_bind, "classdb_get_method_bind")
        && load(get, ptrcall, "object_method_bind_ptrcall")
        && load(get, register_class, "classdb_register_extension_class4");
    if (!loaded) return false;
    initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_CORE;
    initialization->initialize = initialize;
    initialization->deinitialize = deinitialize;
    initialization->userdata = nullptr;
    return true;
}
