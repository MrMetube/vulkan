#+vet explicit-allocators
package main

MaxEventCount :: #config(MaxProfileEventCount, 500_000)

Profile_Event_Table :: struct {
    current_array_index: u32,
    record_increment:    u32,
    
    state: Profile_Events_State,
    events: [2] [MaxEventCount] Profile_Event,
}

Profile_Event_Table_With_Data :: struct ($Data: typeid) {
    using base: Profile_Event_Table,
    event_data: [2] [MaxEventCount] Data,
}

// @volatile is treated as a plain u32 for an atomic add later on
Profile_Events_State :: bit_field u32 { 
    event_index: u32 | 31,
    array_index: u32 | 1,
}

Profile_Event :: struct {
    name:      string,
    timestamp: i64,
    kind:      Profile_Event_Kind,
}

Profile_Event_Kind :: enum u8 {
    BeginZone,
    EndZone,
    UserEvent,
}

Profile_Zone :: struct {
    name: string,
    // tree of zones
    parent_zone_index:  u32,
    first_child_index:  u32,
    last_child_index:   u32,
    next_sibling_index: u32,
    // list of user events that happened inside this zone
    first_user_event:   u32,
    
    event_index_of_zone_begin: u32,
    
    parent_relative_timestamp: i64,
    duration:                  i64,
    duration_with_children:    i64,
}

Stored_User_Event :: struct {
    next_sibling: u32,
    
    using event: Profile_Event,
}

////////////////////////////////////////////////

set_recording :: proc (table: ^Profile_Event_Table, active: bool) {
    table.record_increment = active ? 1 : 0
}

record_event :: proc (table: ^Profile_Event_Table, timestamp: i64, kind: Profile_Event_Kind, name: string) {
    if table == nil { return }
    
    state := transmute(Profile_Events_State) atomic_add(cast(^u32) &table.state, table.record_increment)
    
    table.events[state.array_index][state.event_index] = {
        name       = name,
        timestamp  = timestamp,
        kind       = kind,
    }
}

record_event_with_data :: proc (table: ^Profile_Event_Table_With_Data($Data), timestamp: i64, kind: Profile_Event_Kind, name: string, data: Data) {
    if table == nil { return }
    
    state := transmute(Profile_Events_State) atomic_add(cast(^u32) &table.state, table.record_increment)
    
    table.events[state.array_index][state.event_index] = {
        name       = name,
        timestamp  = timestamp,
        kind       = kind,
    }
    
    table.event_data[state.array_index][state.event_index] = data
}

////////////////////////////////////////////////

swap_active_array_and_get_events :: proc (table: ^Profile_Event_Table) -> [] Profile_Event {
    array_index := table.current_array_index == 0 ? cast(u32) 1 : 0
    state  := atomic_exchange(&table.state, { event_index = 0, array_index = array_index })
    events := table.events[state.array_index][:state.event_index]
    return events
}

swap_active_array_and_get_events_with_data :: proc (table: ^Profile_Event_Table_With_Data($Data)) -> ([] Profile_Event, [] Data) {
    array_index := table.current_array_index == 0 ? cast(u32) 1 : 0
    state  := atomic_exchange(&table.state, { event_index = 0, array_index = array_index })
    events := table.events[state.array_index][:state.event_index]
    data   := table.event_data[state.array_index][:state.event_index]
    return events, data
}

collate_events :: proc (events: [] Profile_Event, zones: ^[dynamic] Profile_Zone, user_events: ^[dynamic] Stored_User_Event) {
    clear(zones)
    clear(user_events)
    
    Open_Zone :: struct {
        zone_index:  u32,
        begin_timestamp: i64,
    }
    
    open_zones := make([dynamic] Open_Zone, context.temp_allocator)
    
    for event, event_index in events {
        begin_timestamp: i64
        end_timestamp:   i64
        
        zone:  ^Profile_Zone
        parent_index: Maybe(u32)
        
        create_zone: bool
        timestamp_basis: i64
        
        switch event.kind {
        case .BeginZone:
            if len(open_zones) > 0 {
                open_parent := last(open_zones)
                timestamp_basis = open_parent.begin_timestamp
                parent_index    = open_parent.zone_index
            }
            
            create_zone = true
            begin_timestamp = event.timestamp
            
        case .EndZone:
            open        := pop(&open_zones)
            
            end_timestamp = event.timestamp
            zone = &zones[open.zone_index]
            if len(open_zones) > 0 {
                open_parent := last(open_zones)
                if open_parent.zone_index != open.zone_index {
                    parent_index = open_parent.zone_index
                }
            }
            
        case .UserEvent:
            if user_events != nil {
                user_index := cast(u32) len(user_events)
                user_event := append_into(user_events)
                
                parent_zone := &zones[last(open_zones).zone_index]
                user_event.next_sibling = parent_zone.first_user_event
                user_event.event = event
                parent_zone.first_user_event = user_index
            }
        }
        
        if create_zone {
            zone_index := cast(u32) len(zones)
            
            open := append_into(&open_zones)
            open^ = {
                zone_index      = zone_index,
                begin_timestamp = event.timestamp,
            }
            
            zone = append_into(zones)
            
            zone^ = {
                name = event.name,
                event_index_of_zone_begin = cast(u32) event_index,
                parent_relative_timestamp = event.timestamp - timestamp_basis,
            }
            
            if parent_index, ok := parent_index.?; ok {
                parent := &zones[parent_index]
                if parent.first_child_index == 0 {
                    assert(zone_index != 0)
                    parent.first_child_index = zone_index
                }
                zones[parent.last_child_index].next_sibling_index = zone_index
                parent.last_child_index = zone_index
            }
        }
        
        if zone != nil {
            zone.duration               += end_timestamp - begin_timestamp
            zone.duration_with_children += end_timestamp - begin_timestamp
        }
        
        if parent_index, ok := parent_index.?; ok {
            parent := &zones[parent_index]
            parent.duration -= end_timestamp - begin_timestamp
        }
    }
}