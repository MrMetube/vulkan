#+vet explicit-allocators
package main

MaxEventCount :: 500_000

Event_Table :: struct {
    current_array_index: u32,
    record_increment:    u32,
    
    state: Events_State,
    events: [2] [MaxEventCount] Event,
}

Event_Table_With_Data :: struct ($Data: typeid) {
    #subtype using 
    base:       Event_Table,
    event_data: [2] [MaxEventCount] Data,
}

// @volatile is treated as a plain u32 for an atomic add later on
Events_State :: bit_field u32 { 
    event_index: u32 | 31,
    array_index: u32 | 1,
}

// @todo thread index? or is that user data
Event :: struct {
    name: string,
    
    timestamp:  i64,
    user_index: u32,
    user_kind:  u16,
    kind:       Event_Kind,
}

// @todo FrameBegin
Event_Kind :: enum u8 {
    BeginFrame,
    BeginZone,
    EndZone,
    UserEvent,
}

Zone :: struct {
    name: string,
    // tree of zones and user events contained in this zone
    parent_zone_index:  u32,
    next_sibling_index: u32,
    first_child_index:  u32,
    last_child_index:   u32,
    first_user_event:   u32,
    
    parent_relative_timestamp: i64,
    duration:                  i64,
    duration_of_children:      i64,
    
    // the additional user data attached to the BeginZone
    user_index: u32,
    user_kind:  u16,
}

Stored_User_Event :: struct {
    next_sibling: u32,
    
    using event: Event,
}

Open_Zone :: struct {
    zone_index:  u32,
    event_index: u32,
    begin_timestamp: i64,
}

the_event_table: ^Event_Table

set_recording :: proc (table: ^Event_Table, active: bool) {
    table.record_increment = active ? 1 : 0
}

swap_active_array_and_get_events :: proc (table: ^Event_Table) -> [] Event {
    array_index := table.current_array_index == 0 ? cast(u32) 1 : 0
    state  := atomic_exchange(&table.state, { event_index = 0, array_index = array_index })
    events := table.events[state.array_index][:state.event_index]
    return events
}

record_event :: proc (timestamp: i64, event_kind: Event_Kind, name : string, user_kind: u16 = 0, data_index: u32 = 0) {
    state := transmute(Events_State) atomic_add(cast(^u32) &the_event_table.state, the_event_table.record_increment)
    result := &the_event_table.events[state.array_index][state.event_index]
    result^ = {
        name = name,
        
        timestamp  = timestamp,
        kind       = event_kind,
        user_kind  = user_kind,
        user_index = data_index,
    }
}

collate_events :: proc (events: [] Event, zones: ^[dynamic] Zone, user_events: ^[dynamic] Stored_User_Event, frame_begin_timestamp: i64 = 0) {
    clear(zones)
    clear(user_events)
    
    open_zones := make([dynamic] Open_Zone, context.temp_allocator)
    
    for event, event_index in events {
        begin_timestamp: i64
        end_timestamp:   i64
        
        zone:  ^Zone
        parent_index: Maybe(u32)
        
        create_zone: bool
        timestamp_basis: i64
        
        switch event.kind {
        case .BeginFrame:
            append(&open_zones, Open_Zone { event_index = 0, begin_timestamp = event.timestamp })
            
            create_zone = true
            begin_timestamp = event.timestamp
            
        case .BeginZone:
            open_parent := last(open_zones)
            timestamp_basis = open_parent.begin_timestamp
            
            create_zone = true
            
            begin_timestamp = event.timestamp
            parent_index = open_parent.zone_index
            
        case .EndZone:
            open        := pop(&open_zones)
            open_parent := last(open_zones)
            
            end_timestamp = event.timestamp
            zone = &zones[open.zone_index]
            if open_parent.zone_index != open.zone_index {
                parent_index = open_parent.zone_index
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
                zone_index = zone_index,
                
                begin_timestamp = event.timestamp,
                event_index     = cast(u32) event_index,
            }
            
            zone = append_into(zones)
            
            zone^ = {
                name = event.name,
                
                parent_relative_timestamp = event.timestamp - timestamp_basis,
                
                user_index = event.user_index,
                user_kind  = event.user_kind,
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
            zone.duration             += end_timestamp - begin_timestamp
            zone.duration_of_children += end_timestamp - begin_timestamp
        }
        
        if parent_index, ok := parent_index.?; ok {
            parent := &zones[parent_index]
            
            parent.duration             -= end_timestamp - begin_timestamp
            parent.duration_of_children += end_timestamp - begin_timestamp
        }
    }
}
