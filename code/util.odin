#+vet !unused-procedures
#+no-instrumentation
package main

import "base:intrinsics"
import "base:runtime"

import "core:simd"

_ :: simd

// ------- Low Contrast
// #C1B28B gray

// ------- High Contrast
// #009052 green

// #0b6773 nay blue v4{0.04, 0.4, 0.45, 1}
// #2EC4B6 sea green
// #7C7A8B taupe gray
// #FF7E6B salmon

// #C92F5F rose
// #12a4cc blue
// #9B1144 wine
// #fe163d red
// #e46738 hazel 
// #ffb433 orange 

Isabelline :: v4{0.96, 0.95, 0.94 , 1}
Jasmine    :: v4{0.95, 0.82, 0.52 , 1}
DarkGreen  :: v4{0   , 0.07, 0.035, 1}
Emerald    :: v4{0.21, 0.82, 0.54 , 1}
Salmon     :: v4{1   , 0.49, 0.42 , 1}
Hazel      :: v4{0.89, 0.4,  0.22 , 1}

White      :: v4{1   , 1   , 1    , 1}
Gray       :: v4{0.5 , 0.5 , 0.5  , 1}
Black      :: v4{0   , 0   , 0    , 1}
Blue       :: v4{0.08, 0.49, 0.72 , 1}
Orange     :: v4{1   , 0.71, 0.2  , 1}
Green      :: v4{0   , 0.59, 0.28 , 1}
Red        :: v4{1   , 0.09, 0.24 , 1}
DarkBlue   :: v4{0.08, 0.08, 0.2  , 1}
DarkGrey   :: v4{0.08, 0.08, 0.08 , 1}

SeaGreen :: v4{0.18, 0.77, 0.71, 1}

color_wheel :: [?] v4 {
    v4{0.08, 0.38, 0.43, 1}, 
    v4{0.99, 0.96, 0.69, 1}, 
    v4{1   , 0.5 , 0.07, 1}, 
    v4{0.92, 0.32, 0.44, 1}, 
    v4{0.38, 0.55, 0.28, 1},  
    v4{1   , 0.56, 0.45, 1}, 
    
    v4{0.53, 0.56, 0.6 , 1}, 
    v4{0.51, 0.2 , 0.02, 1}, 
    v4{0.83, 0.32, 0.07, 1}, 
    v4{0.98, 0.63, 0.25, 1}, 
    v4{0.5 , 0.81, 0.66, 1}, 
    v4{1   , 0.62, 0.7 , 1}, 
    v4{0.49, 0.82, 0.51, 1}, 
    v4{1   , 0.84, 0.4 , 1}, 
    v4{0   , 0.62, 0.72, 1}, 
    v4{0.9 , 0.9 , 0.92, 1}, 
}

pmm :: rawptr
umm :: uintptr

////////////////////////////////////////////////

Byte     :: 1
Kilobyte :: 1024 * Byte
Megabyte :: 1024 * Kilobyte
Gigabyte :: 1024 * Megabyte
Terabyte :: 1024 * Gigabyte
Petabyte :: 1024 * Terabyte
Exabyte  :: 1024 * Petabyte

align        :: proc (#any_int alignment: u64, value: $T) -> T    { return (value + (cast(T) alignment-1)) &~ (cast(T) alignment-1) }
align_offset :: proc (#any_int alignment: u64, value: $T) -> T    { return (value & (cast(T) alignment-1)) }
is_aligned   :: proc (#any_int alignment: u64, value: $T) -> bool { return align_offset(alignment, value) == 0 }

safe_truncate :: proc ($R: typeid, value: $T) -> R where size_of(T) > size_of(R), intrinsics.type_is_integer(T), intrinsics.type_is_integer(R) {
    assert(value <= cast(T) max(R))
    result := cast(R) value
    return result
}

@(require_results) rec_cast :: proc ($T: typeid, rec: $R/Rectangle([$N] $E)) -> Rectangle([N] T) where T != E {
    return { vec_cast(T, rec.min), vec_cast(T, rec.max)}
}
vec_cast :: proc { vcast_2, vcast_3, vcast_4, vcast_vec }
@(require_results) vcast_2 :: proc ($T: typeid, x, y: $E) -> [2] T where T != E {
    return {cast(T) x, cast(T) y}
}
@(require_results) vcast_3 :: proc ($T: typeid, x, y, z: $E) -> [3] T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}
@(require_results) vcast_4 :: proc ($T: typeid, x, y, z, w: $E) -> [4] T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}
@(require_results) vcast_vec :: proc ($T: typeid, v: [$N] $E) -> [N] T where T != E {
    result := cast([N] T) v
    return result
}

vec_max :: proc (a: $T, b: T) -> T {
    result: T
    when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = vec_max(a[i], b[i])
        }
    } else when intrinsics.type_is_simd_vector(T) {
        result = simd.max(a, b)
    } else {
        result = max(a, b)
    }
    return result
}

vec_min :: proc (a: $T, b: T) -> T {
    result: T
    when intrinsics.type_is_simd_vector(T) {
        result = simd.min(a, b)
    } else when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = vec_min(a[i], b[i])
        }
    } else {
        result = min(a, b)
    }
    return result
}

vec_abs :: proc (a: $T) -> T {
    result: T
    when intrinsics.type_is_simd_vector(T) {
        result = simd.abs(a)
    } else when intrinsics.type_is_array(T) {
        #no_bounds_check #unroll for i in 0..<len(T) {
            result[i] = vec_abs(a[i])
        }
    } else {
        result = abs(a)
    }
    return result
}

swap :: proc (a, b: ^$T ) { a^, b^ = b^, a^ }

unused :: proc (_: $T) {}

append_into :: proc { append_into_array, append_into_fixed_array }
append_into_array :: proc (array: ^[dynamic] $T) -> ^T {
    appended := append_nothing(array)
    result: ^T 
    if appended != 0 {
        result = last(array^)
    }
    return result
}
append_into_fixed_array :: proc (array: ^[dynamic; $N] $T) -> ^T {
    appended, ok := append_nothing(array)
    result: ^T 
    if appended != 0 && ok {
        result = last(array)
    }
    return result
}

last :: proc { last_slice, last_array, last_fixed_array }
last_fixed_array :: proc (array: ^[dynamic; $N] $T) -> ^T {
    result := last(array[:])
    return result
}
last_array :: proc (array: [dynamic] $T) -> ^T {
    result := last(array[:])
    return result
}
last_slice :: proc (array: [] $T) -> ^T {
    result: ^T
    #no_bounds_check \
    if len(array) > 0 {
        result = &array[len(array)-1]
    }
    return result
}

peek :: proc (s: [] $T) -> (T, bool) {
    if len(s) == 0 { return {}, false }
    
    result := s[len(s)-1]
    return result, true
}

absolute_difference :: proc (a, b: $T) -> T {
    result: T
    when T == v3 {
        result = abs_vec(a - b)
    } else {
        result = abs(a - b)
    }
    return result
}

@(disabled=ODIN_DISABLE_ASSERT)
assert :: proc (condition: $B, message := #caller_expression(condition), loc := #caller_location, prefix := "Assertion failed") where intrinsics.type_is_boolean(B) {
    if !condition {
        print("%v %v", loc, prefix)
        if len(message) > 0 {
            print(": %v\n", message)
        }
        
        when ODIN_DEBUG {
             runtime.debug_trap()
        } else {
            runtime.trap()
        }
    }
}

slice_from_parts :: proc { slice_from_parts_type, slice_from_parts_type_of_data_pointer }
slice_from_parts_type :: proc ($T: typeid, data: pmm, #any_int count: i64) -> [] T {
    return (cast([^]T) data)[:count] // :PointerArithmetic
}
slice_from_parts_type_of_data_pointer :: proc (data: ^$T, #any_int count: i64) -> [] T {
    return (cast([^]T) data)[:count] // :PointerArithmetic
}

array_from_parts :: proc ($T: typeid, data: pmm, #any_int length, capacity: int, allocator: Maybe(Allocator) = nil) -> [dynamic] T {
    result := Raw_Dynamic_Array {
        data = data,
        len  = length,
        cap  = capacity,
        allocator = allocator.? or_else runtime.nil_allocator(),
    } 
    return transmute([dynamic] T) result
}

                
slice_to_bytes :: proc (value: [] $T) -> [] u8 {
    data := raw_data(value)
    len  := size_of_slice(value)
    result := slice_from_parts(u8, data, len)
    return result
}
size_of_slice :: proc (value: [] $T) -> umm {
    result := size_of(T) * cast(umm) len(value)
    return result
}
to_bytes :: proc (value: ^$T) -> [] u8 {
    result := (cast([^] u8) value)[:size_of(T)]
    return result
}

make_by_pointer :: proc {
    make_by_pointer_slice,
    make_by_pointer_dynamic_array,
    make_by_pointer_dynamic_array_len,
    make_by_pointer_dynamic_array_len_cap,
    make_by_pointer_map,
    make_by_pointer_map_cap,
    make_by_pointer_multi_pointer,
    make_by_pointer_soa_slice,
    make_by_pointer_soa_dynamic_array,
    make_by_pointer_soa_dynamic_array_len,
    make_by_pointer_soa_dynamic_array_len_cap,
}

make_by_pointer_slice                     :: proc (pointer: ^$T/[] $E,             #any_int len: int,      allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, len,      allocator, loc) or_return;  return nil }
make_by_pointer_dynamic_array             :: proc (pointer: ^$T/[dynamic] $E,                              allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T,           allocator, loc) or_return;  return nil }
make_by_pointer_dynamic_array_len         :: proc (pointer: ^$T/[dynamic] $E,      #any_int len: int,      allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, len,      allocator, loc) or_return;  return nil }
make_by_pointer_dynamic_array_len_cap     :: proc (pointer: ^$T/[dynamic] $E,      #any_int len, cap: int, allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, len, cap, allocator, loc) or_return;  return nil }
make_by_pointer_map                       :: proc (pointer: ^$T/map[$K] $E,                                allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T,           allocator, loc);            return nil }
make_by_pointer_map_cap                   :: proc (pointer: ^$T/map[$K] $E,        #any_int cap: int,      allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, cap,      allocator, loc) or_return;  return nil }
make_by_pointer_multi_pointer             :: proc (pointer: ^$T/[^] $E,            #any_int len: int,      allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, len,      allocator, loc) or_return;  return nil }
make_by_pointer_soa_slice                 :: proc (pointer: ^$T/#soa [] $E,        #any_int len: int,      allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, len,      allocator, loc) or_return;  return nil }
make_by_pointer_soa_dynamic_array         :: proc (pointer: ^$T/#soa [dynamic] $E,                         allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T,           allocator, loc) or_return;  return nil }
make_by_pointer_soa_dynamic_array_len     :: proc (pointer: ^$T/#soa [dynamic] $E, #any_int len: int,      allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, len,      allocator, loc) or_return;  return nil }
make_by_pointer_soa_dynamic_array_len_cap :: proc (pointer: ^$T/#soa [dynamic] $E, #any_int len, cap: int, allocator := context.allocator, loc := #caller_location) -> Allocator_Error { pointer ^= make(T, len, cap, allocator, loc) or_return;  return nil }

make_shallow_copy :: proc { make_shallow_copy_array, make_shallow_copy_slice, make_shallow_copy_soa }
make_shallow_copy_array :: proc (source: $A/ [dynamic] $T, allocator: Allocator) -> A {
    result := make(A, len(source), allocator)
    copy(result[:], source[:])
    return result
}
make_shallow_copy_slice :: proc (source: $A/ [] $T, allocator: Allocator) -> A {
    result := make(A, len(source), allocator)
    copy(result, source[:])
    return result
}
make_shallow_copy_soa :: proc (source: $A/ #soa [dynamic] $T, allocator: Allocator) -> A {
    result := make(A, len(source), allocator)
    
    for it, index in source {
        result[index] = it
    }
    
    return result
}

zero_slice :: proc (data: $T/ [] $E) -> T {
	intrinsics.mem_zero(raw_data(data), size_of(E) * len(data))
	return data
}

////////////////////////////////////////////////

Allocator          :: runtime.Allocator
Allocator_Error    :: runtime.Allocator_Error
Allocator_Mode     :: runtime.Allocator_Mode
Allocator_Mode_Set :: runtime.Allocator_Mode_Set

Raw_Dynamic_Array :: struct {
    data: rawptr,
    len:  int,
    cap:  int,
    allocator: Allocator,
}
RawSlice :: struct {
    data: rawptr,
    len:  int,
}
RawAny :: struct {
    data: rawptr,
	id:   typeid,
}

////////////////////////////////////////////////
// Preventing compiler optimizations like Dead Code Elimination

// @study: can we also make a force_compiler_to_set(pointer, value) version?

pretend_to_write :: #force_inline proc "contextless" (pointer: ^$T) {
    asm (^T) {"", "m"} (pointer)
}

pretend_to_read :: #force_inline proc "contextless" (pointer: ^$T) {
    asm (^T) {"", "m"} (pointer)
}

////////////////////////////////////////////////

// https://graphics.stanford.edu/~seander/bithacks.html#RoundUpPowerOf2
next_power_of_two :: proc (v: u32) -> u32 {
    result := v
    
    result -= 1
    result |= result >> 1
    result |= result >> 2
    result |= result >> 4
    result |= result >> 8
    result |= result >> 16
    result += 1
    
    return result
}

previous_power_of_two :: proc (v: u32) -> u32 {
    result := #force_inline next_power_of_two(v)
    result >>= 1
    
    return result
}

integer_log2 :: proc (x: u32) -> u32 {
	return (32-1) - intrinsics.count_leading_zeros(x)
}