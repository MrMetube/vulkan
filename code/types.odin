#+vet !unused-procedures
package main

Byte_Buffer :: struct {
    bytes:        [] u8,
    read_cursor:  int,
    write_cursor: int,
}

make_byte_buffer :: proc (buffer: [] u8) -> Byte_Buffer {
    result := Byte_Buffer { bytes = buffer }
    return result
}

write_reserve :: proc (b: ^Byte_Buffer, $T: typeid) -> ^T {
    dest := b.bytes[b.write_cursor:]
    size := size_of(T)
    assert(len(dest) >= size)
    
    result := cast(^T) &dest[0]
    b.write_cursor += size
    
    return result
}

write_slice :: proc (b: ^Byte_Buffer, values: [] $T) {
    dest := b.bytes[write_cursor:]
    assert(len(dest) >= len(source))
    source := slice_from_parts(u8, raw_data(values), len(values) * size_of(T))
    copy(dest, source)
    b.write_cursor += len(source)
}

write :: proc (b: ^Byte_Buffer, value: $T) {
    dest := b.bytes[write_cursor:]
    assert(len(dest) >= size_of(T))
    value := value
    source := slice_from_parts(u8, &value, size_of(T))
    copy(dest, source)
    b.write_cursor += len(source)
}

write_align :: proc (b: ^Byte_Buffer, #any_int alignment: int) {
    // @todo(viktor): ensure that alignment is a power of two
    remainder := b.write_cursor % alignment
    if b.write_cursor % alignment != 0 {
        offset := alignment - remainder
        assert(b.write_cursor + offset < len(b.bytes))
        b.write_cursor += offset
    }
}

read :: proc (b: ^Byte_Buffer, $T: typeid) -> ^T {
    source := b.bytes[b.read_cursor:]
    assert(size_of(T) <= len(source))
    
    result := cast(^T) &source[0]
    b.read_cursor += size_of(T)
    
    return result
}

read_into :: proc (b: ^Byte_Buffer, value: ^^$T) {
    value ^= read(b, T)
}

read_slice :: proc (b: ^Byte_Buffer, $T: typeid/ [] $E, count: int) -> [] E {
    size := count * size_of(E)
    source := b.bytes[b.read_cursor:]
    assert(size <= len(source))
    result := source[:size]
    b.read_cursor += size
    
    return result
}

read_string :: proc (b: ^Byte_Buffer, count: int) -> string {
    bytes := read_slice(b, [] u8, count)
    result := transmute(string) bytes
    return result
}

begin_reading :: proc (b: ^Byte_Buffer) { b.read_cursor = 0 }
can_read        :: proc (b: Byte_Buffer) -> bool { return b.read_cursor < b.write_cursor }
read_everything :: proc (b: Byte_Buffer) -> bool { return !can_read(b) }

clear_byte_buffer :: proc (b: ^Byte_Buffer) {
    b.read_cursor = 0
    b.write_cursor = 0
}