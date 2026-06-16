#+vet !unused-procedures
#+no-instrumentation
package main

import "base:intrinsics"


RandomSeries :: struct {
    state: lane_u32,
}

seed_random_series :: proc(#any_int seed: u32) -> RandomSeries {
    result := RandomSeries { state = seed }
    result.state ~= (lane_offset + 4) * seed
    return result
}

next_random_lane_u32 :: xor_shift
next_random_u32 :: proc (series: ^RandomSeries) -> u32 {
    next_random_lane_u32(series)
    return extract(series.state, 0)
}
xor_shift :: proc (series: ^RandomSeries) ->  lane_u32 {
    // @note(viktor): Reference xor_shift from https://en.wikipedia.org/wiki/Xorshift
    x := series.state 
        
    x ~= shift_left( x, 13)
    x ~= shift_right(x, 17)
    x ~= shift_left( x,  5)
    
    series.state = x
    
    return x
}

// @todo(viktor): why are all results less than 0.001 ?
random_unilateral :: proc { random_unilateral_scalar, random_unilateral_array, random_unilateral_vector }
random_unilateral_scalar :: proc(series: ^RandomSeries, $T: typeid) -> T where !intrinsics.type_is_simd_vector(T), !intrinsics.type_is_array(T) {
    unilateral := random_unilateral(series)
    result := extract(unilateral, 0)
    return result
}
random_unilateral_array :: proc (series: ^RandomSeries, $T: typeid/ [$N] $E) -> T {
    result: T
    #no_bounds_check #unroll for i in 0..<len(T) {
        result[i] = random_unilateral(series, E)
    }
    return result
}
random_unilateral_vector :: proc (series: ^RandomSeries) -> lane_f32 {
    random_value := next_random_lane_u32(series)
    result := cast(lane_f32) (shift_right(random_value, 1)) / cast(lane_f32) (max(u32) >> 1)
    return result
}

random_bilateral :: proc(series: ^RandomSeries, $T: typeid) -> T {
    result := random_unilateral(series, T)
    result = result * 2 - 1
    return result
}



random_choice :: proc { random_choice_integer_0_max, random_choice_integer_min_max, random_choice_data, random_choice_bitset }
random_choice_integer_0_max :: proc(series: ^RandomSeries, max: u32) -> u32 {
    result := next_random_u32(series) % max
    return result
}
random_choice_integer_min_max :: proc(series: ^RandomSeries, min, max: u32) -> u32 {
    result := next_random_u32(series) % (max - min) + min
    return result
}
random_choice_data :: proc(series: ^RandomSeries, data: [] $T) -> ^T {
    result := &data[random_choice(series, auto_cast len(data))]
    return result
}
random_choice_index :: proc(series: ^RandomSeries, data: [] $T) -> (^T, u32) {
    index := random_choice(series, auto_cast len(data))
    result := &data[index]
    return result, index
}

random_choice_bitset :: proc (series: ^RandomSeries, set: bit_set[$E]) -> E {
    count := cast(u32) card(set)
    index := random_between_u32(series, 0, count-1)
    
    result: E
    for element in set {
        if index == 0 {
            result = element
            break
        }
        index -= 1
    }
    
    return result
}

random_between_i32 :: proc(series: ^RandomSeries, min, max: i32) -> i32 {
    assert(min < max)
    result := min + cast(i32)(next_random_u32(series) % cast(u32)((max+1)-min))
    
    return result
}

random_between_u32 :: proc(series: ^RandomSeries, min, max: u32) -> u32 {
    assert(min <= max)
    result := min + (next_random_u32(series) % ((max+1)-min))
    assert(result >= min)
    assert(result <= max)
    return result
}

random_between_f32 :: proc(series: ^RandomSeries, min, max: f32) -> f32 {
    assert(min < max)
    value := random_unilateral(series, f32)
    range := max - min
    result := min + value * range
    assert(result >= min)
    assert(result <= max)
    return result
}