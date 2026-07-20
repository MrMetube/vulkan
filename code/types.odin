#+vet !unused-procedures
package main

////////////////////////////////////////////////
// @note(viktor): writing and reading need to be in sync or we get undefined behaviour. We could always write the type of a value in combination with that value and then on read assert that the next type to read is the same as the requested type of the parameter.
// @todo(viktor): most of these calls are untested and need to checked and verified

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

read_align :: proc (b: ^Byte_Buffer, #any_int alignment: int) {
    // @todo(viktor): ensure that alignment is a power of two
    remainder := b.read_cursor % alignment
    if b.read_cursor % alignment != 0 {
        offset := alignment - remainder
        assert(b.read_cursor + offset < len(b.bytes))
        b.read_cursor += offset
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

////////////////////////////////////////////////
// [First] <- [..] ... <- [..] <- [Last] 
Deque :: struct($L: typeid) {
    first, last: ^L,
}

deque_prepend :: proc (deque: ^Deque($L), element: ^L) {
    if deque.first == nil {
        assert(deque.last == nil)
        deque.last  = element
        deque.first = element
    }  else {
        element.next = deque.last
        deque.last   = element
    }
}

deque_append :: proc (deque: ^Deque($L), element: ^L) {
    if deque.first == nil {
        assert(deque.last == nil)
        deque.last  = element
        deque.first = element
    }  else {
        deque.first.next = element
        deque.first      = element
    }
}

deque_remove_from_end :: proc (deque: ^Deque($L)) -> ^L {
    result := deque.last
    
    if result != nil {
        deque.last = result.next

        if result == deque.first {
            assert(result.next == nil)
            deque.first = nil
        }
    }
    
    return result
}

////////////////////////////////////////////////
// Double Linked List
// [Sentinel] -> <- [..] ->
//  -> <- [..] -> ...    <-

list_init_sentinel :: proc (sentinel: ^$T) {
    sentinel.next = sentinel
    sentinel.prev = sentinel
}

list_prepend :: proc (list: ^$T, element: ^T) {
    element.prev = list.prev
    element.next = list
    
    element.next.prev = element
    element.prev.next = element
}

list_append :: proc (list: ^$T, element: ^T) {
    element.next = list.next
    element.prev = list
    
    element.next.prev = element
    element.prev.next = element
}

list_remove :: proc (element: ^$T) {
    element.prev.next = element.next
    element.next.prev = element.prev
    
    element.next = nil
    element.prev = nil
}

///////////////////////////////////////////////
// Single Linked List
// [Head] -> [..] ... -> [..] -> [Tail]

list_push :: proc { list_push_next, list_push_next_pointer }
list_push_next :: proc (head: ^^$T, element: ^T) {
    list_push(head, element, &element.next)
}
list_push_next_pointer :: proc (head: ^^$T, element: ^T, next: ^^T) {
    next^ = head^
    head^ = element
}


list_pop_head:: proc { list_pop_head_next, list_pop_head_next_offset }
list_pop_head_next :: proc (head: ^^$T) -> (result: ^T, ok: b32) #optional_ok { 
    result, ok = list_pop_head(head, offset_of(T, next))
    return result, ok
}
list_pop_head_next_offset :: proc (head: ^^$T, $next_offset: umm) -> (result: ^T, ok: b32) #optional_ok {
    ok = head^ != nil
    if ok {
        result = head^
        next  := cast(^^T) (cast(umm) result + next_offset)
        head^  = next^
    }
    
    return result, ok
}
