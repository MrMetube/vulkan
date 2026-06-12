package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Catalogue :: struct ($T: typeid) {
    allocator: Allocator,
    entries: [dynamic] Catalogue_Entry,
    values:  [dynamic] T,
}

Catalogue_Entry :: struct {
    name: string,
    full_path: string,
    read_time: time.Time,
}

Catalogue_Iterator :: struct ($T: typeid) {
    catalogue: ^Catalogue(T),
    // for changed files
    index:     int,
    // for setup files
    dir:      ^os.File,
    dir_iter: os.Read_Directory_Iterator,
}

////////////////////////////////////////////////

catalogue_make :: proc ($T: typeid, allocator := context.allocator) -> Catalogue(T) {
    result: Catalogue(T)
    
    result.allocator = allocator
    result.entries.allocator = result.allocator
    
    return result
}

////////////////////////////////////////////////

catalogue_begin_setup :: proc (catalogue: ^Catalogue($T), directory: string) -> Catalogue_Iterator(T) {
    result: Catalogue_Iterator(T)
    result.catalogue = catalogue
    
    result.dir, _   = os.open(directory)
    result.dir_iter = os.read_directory_iterator_create(result.dir)
    
    return result
}

catalogue_setup_files :: proc (iter: ^Catalogue_Iterator($T), extensions: ..string) -> (value: ^T, entry: Catalogue_Entry, ok: bool) {
    for {
        info, _, info_ok := os.read_directory_iterator(&iter.dir_iter)
        if !info_ok {
            return value, entry, ok
        }
        
        matches: bool
        check: for extension in extensions {
            if strings.ends_with(info.fullpath, extension) {
                matches = true
                break check
            }
        }
        
        if matches {
            catalogue := iter.catalogue
            append(&iter.catalogue.entries, Catalogue_Entry {
                read_time = info.modification_time,
                full_path = strings.clone(info.fullpath, catalogue.allocator),
                name      = strings.clone(info.name, catalogue.allocator),
            })
            
            value = append_into(&catalogue.values)
            entry = last(catalogue.entries)^
            
            return value, entry, true
        }
    }
}

catalogue_end_setup :: proc (iter: ^Catalogue_Iterator($T)) {
    os.read_directory_iterator_destroy(&iter.dir_iter)
    os.close(iter.dir)
}

////////////////////////////////////////////////

catalogue_begin_changed :: proc (catalogue: ^Catalogue($T)) -> Catalogue_Iterator(T) {
    result: Catalogue_Iterator(T)
    result.catalogue = catalogue
    
    return result
}

catalogue_changed_files :: proc (iter: ^Catalogue_Iterator($T)) -> (value: ^T, ok: bool) {
    for {
        index := iter.index
        iter.index += 1
        
        ok = index < len(iter.catalogue.entries)
        if !ok do break
        
        entry := &iter.catalogue.entries[index]
        info, err := os.stat(entry.full_path, context.temp_allocator)
        if err != nil {
            fmt.eprintfln("Failed to check modification time of file '%v': %v", entry.full_path, os.error_string(err))
            continue
        }
        
        if entry.read_time._nsec >= info.modification_time._nsec {
            continue
        }
        
        entry.read_time = info.modification_time
        value = &iter.catalogue.values[index]
        
        return value, ok
    }
    
    return nil, ok
}