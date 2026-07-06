#+vet explicit-allocators
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Watcher :: struct {
    path: string,
    
    last_update_time:           time.Time,
    modified_since_last_update: bool,
}

Watcher_Id :: distinct int

////////////////////////////////////////////////

watcher_make :: proc (path: string) -> Watcher {
    result: Watcher
    result.path = path
    return result
}

watchers_make :: proc (watchers: ^[dynamic] Watcher, path: string) -> Watcher_Id {
    watcher := watcher_make(path)
    
    append(watchers, watcher)
    result := cast(Watcher_Id) len(watchers)-1
    
    return result
}

////////////////////////////////////////////////

watchers_check_for_modification :: proc (watchers: [dynamic] Watcher) {
    for &watcher in watchers {
        watcher_check_for_modification(&watcher)
    }
}

watcher_check_for_modification :: proc (watcher: ^Watcher) {
    info, err := os.stat(watcher.path, context.temp_allocator)
    if err != nil {
        fmt.eprintfln("Error: failed get information on the file `%v`: %v", watcher.path, err)
        return
    }
    
    if watcher.last_update_time._nsec < info.modification_time._nsec {
        watcher.modified_since_last_update = true
    }
}

watcher_modified :: proc { watcher_modified_ids, watcher_modified_pointers }
watcher_modified_ids :: proc (watchers: [dynamic] Watcher, ids: ..Watcher_Id) -> bool {
    result := false
    for id in ids {
        result ||= watchers[id].modified_since_last_update
    }
    return result
}
watcher_modified_pointers :: proc (watchers: ..^Watcher) -> bool {
    result := false
    for it in watchers {
        result ||= it.modified_since_last_update
    }
    return result
}

watcher_set_up_to_date :: proc { watcher_set_up_to_date_pointers, watcher_set_up_to_date_ids }
watcher_set_up_to_date_pointers :: proc (watchers: ..^Watcher) {
    for watcher in watchers {
        watcher.modified_since_last_update = false
        watcher.last_update_time = time.now()
    }
}
watcher_set_up_to_date_ids :: proc (watchers: [dynamic] Watcher, ids: ..Watcher_Id) {
    for id in ids {
        watcher := &watchers[id]
        watcher.modified_since_last_update = false
        watcher.last_update_time = time.now()
    }
}