#+vet explicit-allocators
package main

import "core:fmt"
import "core:os"
import "core:time"

Watchers :: distinct [dynamic] Watcher

Watcher :: struct {
    path:             string,
    last_update_time: time.Time,
    
    subscribed: u32,
    notified:   u32,
}

Watcher_Id :: distinct int

////////////////////////////////////////////////

watchers_make :: proc (watchers: ^Watchers, path: string) -> Watcher_Id {
    append(watchers, Watcher {
        path       = path,
    })
    
    result := cast(Watcher_Id) len(watchers)-1
    return result
}

////////////////////////////////////////////////

watchers_check_files_for_modification :: proc (watchers: ^Watchers) {
    profile_procedure()
    
    for &watcher in watchers {
        info, err := os.stat(watcher.path, context.temp_allocator)
        if err != nil {
            fmt.eprintfln("Error: failed get information on the file `%v`: %v", watcher.path, err)
            return
        }
        
        if watcher.last_update_time._nsec < info.modification_time._nsec {
            watcher.notified = 0
        }
    }
}

watcher_check_and_reset :: proc (watchers: ^Watchers, id: Watcher_Id) -> bool {
    watcher := watchers[id]
    
    assert(watcher.subscribed != 0)
    result := watcher.notified != watcher.subscribed
    
    if result {
        watcher_set_up_to_date(watchers, id)
    }
    
    return result
}

watcher_set_up_to_date :: proc (watchers: ^Watchers, id: Watcher_Id) {
    watcher := &watchers[id]
    assert(watcher.notified+1 <= watcher.subscribed)
    watcher.notified += 1
    watcher.last_update_time = time.now()
}

watcher_depend_on :: proc (watchers: ^Watchers, dependency: Watcher_Id) {
    watchers[dependency].subscribed += 1
}