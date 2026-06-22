#+vet explicit-allocators
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import la "core:math/linalg"

import sdl "vendor:sdl3"
import vk  "vendor:vulkan"

////////////////////////////////////////////////

Optimized :: ODIN_OPTIMIZATION_MODE == .Speed

VSync :: true when !Optimized else false

////////////////////////////////////////////////

DescriptorUpdateData :: struct #raw_union {
    buffer: vk.DescriptorBufferInfo,
    image:  vk.DescriptorImageInfo,
}

Geometry :: struct {
    // @todo(viktor): all this data is not needed on the cpu, we could just directly upload it to the gpu buffers
    vertices:     [dynamic] Vertex,
    meshlets:     [dynamic] Meshlet,
    meshlet_data: [dynamic] u32,
    
    meshes: [dynamic] Mesh,
}

Stuff_With_The_Same_Lifetime_As_The_Swapchain :: struct {
    depth_sampler: vk.Sampler, // well except you of course..
    depth_pyramid: Image,
    depth_pyramid_mips: [dynamic; 16] Depth_Pyramid_Mip,
}

////////////////////////////////////////////////

// @shader meshlet.mesh
MaxVertices  :: 64
MaxTriangles :: 84

// @shader cull.comp
Cull_Globals :: struct #all_or_none {
    frustum_planes: [6] v4,
    draw_buffer:         vk.DeviceAddress "Draw",
    mesh_buffer:         vk.DeviceAddress "Mesh",
    draw_command_buffer: vk.DeviceAddress "Draw_Command",
    draw_command_count:  vk.DeviceAddress "uint",
    
    camera_p:   v3,
    draw_count: u32,
    
    frustum_culling_enabled: b32,
    lod_enabled:             b32,
}

// @shader
Draw_Globals :: struct {
    view:       m4,
    projection: m4,
    light_pos:  [4] v4,
    
    draw_command_buffer: vk.DeviceAddress "Draw_Command",
    draw_buffer:         vk.DeviceAddress "Draw",
    mesh_buffer:         vk.DeviceAddress "Mesh",
    meshlet_buffer:      vk.DeviceAddress "Meshlet",
    meshlet_data_buffer: vk.DeviceAddress "uint",
    vertex_buffer:       vk.DeviceAddress "Vertex",
}

// @shader
Depth_Globals :: struct {
    size: v2,
}

// @shader
Draw :: struct {
    orientation: q32,
    p:           v3,
    scale:       f32,
    
    mesh_index:    u32,
    vertex_offset: u32,
    texture_index: u32,
}

// @shader
Mesh :: struct {
    center: v3,
    radius: f32,
    
    vertex_offset: u32,
    vertex_count:  u32,
    
    lod_count: u32,
    lods:      [8] Mesh_LOD,
}

// @shader
Mesh_LOD :: struct {
    meshlet_offset: u32,
    meshlet_count:  u32,
}

// @shader
Draw_Command :: struct {
    draw_id:   u32,
    lod_index: u32,
    command:   vk.DrawMeshTasksIndirectCommandEXT,
    // _pad: u32, // @cleanup it seems the buffer is not correctly written to by the cull.comp shader. the values assuming another padding byte, which the cpu did not assume. CmdDrawMeshTasksIndirectCountEXT then failed to read the correct values as it was given the cpu's alignments and offsets.
}

// @shader
Meshlet :: struct {
    center: v3,
    radius: f32,
    cone_axis:   [3] i8,
    cone_cutoff: i8,
    
    data_offset:    u32, // [data_offset:][:vertexcount]
    vertex_count:   u8,
    triangle_count: u8,
}

// @shader
Vertex :: struct {
    p:  v3,      p_pad: f32,
    n:  [3] u8,  n_pad: u8,
    uv: v2,
}

////////////////////////////////////////////////

main :: proc () {
    defer sdl.Quit()
    
    check(sdl.InitSubSystem({ .VIDEO }))
    defer sdl.QuitSubSystem({ .VIDEO })
    
    window := sdl.CreateWindow("How to Vulkan", 1280, 720, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE)
    check(window != nil)
    defer sdl.DestroyWindow(window)
    
    ////////////////////////////////////////////////
    
    gpu := gpu_init(window)
    
    stuff: Stuff_With_The_Same_Lifetime_As_The_Swapchain
    recreate_stuff(&gpu, &stuff)
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): currently all are allocated to be host visible, so that we can simplify copying into them.
    // Rethink if any of these should be copied to device_local memory
    vb_view,  vertex_buffer        := gpu_allocate(&gpu, [] Vertex,    256 * Megabyte / size_of(Vertex))
    mlb_view, meshlet_buffer       := gpu_allocate(&gpu, [] Meshlet,   256 * Megabyte / size_of(Meshlet))
    mdb_view, meshlet_data_buffer  := gpu_allocate(&gpu, [] u32,       256 * Megabyte / size_of(u32))
    db_view,  draw_buffer          := gpu_allocate(&gpu, [] Draw,      256 * Megabyte / size_of(Draw))
    mb_view,  mesh_buffer          := gpu_allocate(&gpu, [] Mesh,      256 * Megabyte / size_of(Mesh))
    // @todo(viktor): this buffer is never seen by the cpu, its filled by compute and used by task+mesh shader, but for debbuging it really helped that there was a view/slice
    dcb_view, draw_command_buffer := gpu_allocate(&gpu, [] Draw_Command, 256 * Megabyte / size_of(Draw_Command), usage = vk.BufferUsageFlags {  .STORAGE_BUFFER, .INDIRECT_BUFFER })
    dccb_view, draw_command_count_buffer := gpu_allocate_type(&gpu, u32, usage = { .STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST })
    draw_command_buffer_buffer       := the_allocations[draw_command_buffer].buffer
    draw_command_count_buffer_buffer := the_allocations[draw_command_count_buffer.address].buffer
    
    geometry: Geometry
    {
        paths := [?] string {
            "tutorial/suzanne.obj",
            // "models/bunny.obj",
            // "models/lucy_280k.obj",
        }
        
        for path in paths {
            if !load_mesh(&geometry, path, context.temp_allocator) {
                fmt.eprintfln("Failed to load mesh from file `%v`", path)
            }
        }
        
        copy(vb_view,  geometry.vertices[:])
        copy(mlb_view, geometry.meshlets[:])
        copy(mdb_view, geometry.meshlet_data[:])
        copy(mb_view,  geometry.meshes[:])
    }
    
    ////////////////////////////////////////////////
    
    generate_shader_api("shaders/api.generated.glslh")
    
    shader_allocator := context.allocator
    
    shader_files := make([dynamic] string, context.temp_allocator)
    get_all_files_with_extension(&shader_files, "shaders", shader_allocator, ".frag", ".mesh", ".task")
    
    watcher_allocator := context.allocator
    watchers := make([dynamic] Watcher, watcher_allocator)
    
    
    meshlet_shaders: [dynamic] Shader
    for file in shader_files {
        // @speed we duplicate this watcher per shader, so that each shader can keep track of the header being changed and be recompiled independently from other shaders, without effecting their modification test.
        common_watcher_id := watchers_make(&watchers, "shaders/common.glslh")
        shader := init_shader_and_watchers(&watchers, common_watcher_id, file, shader_allocator)
        append(&meshlet_shaders, shader)
    }
    
    draw_cull_shader    := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/draw_cull.comp",    shader_allocator)
    depth_reduce_shader := init_shader_and_watchers(&watchers, watchers_make(&watchers, "shaders/common.glslh"), "shaders/depth_reduce.comp", shader_allocator)
    
    ////////////////////////////////////////////////
    
    // this will hold literally all textures, expand if needed and let the shader index into it via Draw.texture_index
    textures: [3] Image
    texture_descriptors: [len(textures)] vk.DescriptorImageInfo
    
    {
        // @cleanup to do the copy into gpu memory ourselves, we need the tiling to be .LINEAR and not .OPTIMAL, 
        // but in that case we cannot specify any mip_levels. :(
        for &texture, index in textures {
            filename := fmt.tprintf("tutorial/suzanne%v.ktx", index)
            
            loaded_texture := load_ktx_texture(filename, context.temp_allocator)
            
            texture = gpu_make_image(&gpu, {loaded_texture.width, loaded_texture.height}, loaded_texture.format, { .TRANSFER_DST, .SAMPLED }, { .COLOR }, mip_levels = loaded_texture.mip_levels)
            
            source_buffer_data, source_buffer := gpu_allocate_slice(&gpu, [] u8, len(loaded_texture.data), usage = { .TRANSFER_SRC })
            source_buffer_buffer := the_allocations[source_buffer].buffer
            defer gpu_free(&gpu, source_buffer)
            
            // @waste just load directly into this buffer
            copy(source_buffer_data, loaded_texture.data)
            
            ////////////////////////////////////////////////
            
            cmd := gpu_begin_command_recording(&gpu, 0, gpu.queue)
            
            // @todo(viktor): could we just have one semaphore and wait after the loop?
            upload_semaphore := gpu_create_timeline_semaphore(&gpu, 0)
            defer gpu_destroy_semaphore(&gpu, upload_semaphore)
            
            pipeline_barrier_begin()
                add_image_barrier(&texture, {}, {}, .UNDEFINED, { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
            pipeline_barrier_end(cmd)
            
            copy_regions := make([dynamic] vk.BufferImageCopy, context.temp_allocator)
            for level in 0..<loaded_texture.mip_levels {
                mip_offset := loaded_texture.mip_offsets[level]
                
                append(&copy_regions, vk.BufferImageCopy {
                    bufferOffset     = auto_cast mip_offset,
                    imageSubresource = { aspectMask = { .COLOR }, mipLevel = level, layerCount = 1 },
                    imageExtent      = { width = loaded_texture.width >> level, height = loaded_texture.height >> level, depth = 1 },
                })
            }
            
            vk.CmdCopyBufferToImage(cmd, source_buffer_buffer, texture.image, .TRANSFER_DST_OPTIMAL, auto_cast len(copy_regions), raw_data(copy_regions))
            
            pipeline_barrier_begin()
                add_image_barrier_transition_from_last(&texture, { .FRAGMENT_SHADER }, { .SHADER_READ }, .READ_ONLY_OPTIMAL)
            pipeline_barrier_end(cmd)
            
            gpu_submit(gpu.queue, upload_semaphore, 1, cmd)
            gpu_wait_semaphore(&gpu, upload_semaphore, 1)
            
            sampler := create_sampler(gpu.device, .LINEAR, .LINEAR, cast(f32) loaded_texture.mip_levels, true)
            defer_destroy(vk.DestroySampler, sampler)
            
            texture_descriptors[index] = vk.DescriptorImageInfo{ 
                sampler     = sampler, 
                imageView   = texture.view, 
                imageLayout = texture.last_transition.layout
            }
        }
    }
    
    ////////////////////////////////////////////////
    
    textures_descriptor_set_layout: vk.DescriptorSetLayout
    textures_descriptor_set:        vk.DescriptorSet
    {
        pool: vk.DescriptorPool
        
        descriptor_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            pNext = &vk.DescriptorSetLayoutBindingFlagsCreateInfo {
                sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
                bindingCount  = 1,
                pBindingFlags = &vk.DescriptorBindingFlags { .VARIABLE_DESCRIPTOR_COUNT },
            },
            bindingCount = 1,
            pBindings = &vk.DescriptorSetLayoutBinding {
                binding         = 0,
                descriptorType  = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
                stageFlags      = { .FRAGMENT },
            },
        }
        
        check(vk.CreateDescriptorSetLayout(gpu.device, &descriptor_layout_create_info, nil, &textures_descriptor_set_layout))
        defer_destroy(vk.DestroyDescriptorSetLayout, textures_descriptor_set_layout)
        
        descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
            sType = .DESCRIPTOR_POOL_CREATE_INFO,
            maxSets       = 1,
            poolSizeCount = 1,
            pPoolSizes    = &vk.DescriptorPoolSize {
                type = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = len(textures),
            },
        }
        
        check(vk.CreateDescriptorPool(gpu.device, &descriptor_pool_create_info, nil, &pool))
        defer_destroy(vk.DestroyDescriptorPool, pool)
        
        descriptor_count := cast(u32) len(textures)
        
        textures_desc_set_allocate_info := vk.DescriptorSetAllocateInfo {
            sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
            pNext = &vk.DescriptorSetVariableDescriptorCountAllocateInfo {
                sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
                descriptorSetCount = 1,
                pDescriptorCounts  = &descriptor_count,
            },
            descriptorPool     = pool,
            descriptorSetCount = 1,
            pSetLayouts        = &textures_descriptor_set_layout,
        }
        
        check(vk.AllocateDescriptorSets(gpu.device, &textures_desc_set_allocate_info, &textures_descriptor_set))
        
        write_desc_set := vk.WriteDescriptorSet {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = textures_descriptor_set,
            dstBinding = 0,
            descriptorCount = cast(u32) len(texture_descriptors),
            descriptorType = .COMBINED_IMAGE_SAMPLER,
            pImageInfo = &texture_descriptors[0],
        }
        vk.UpdateDescriptorSets(gpu.device, 1, &write_desc_set, 0, nil)
    }
    
    ////////////////////////////////////////////////
    
    gpu_profile_make_query_pool(gpu.device)
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): migrate the depth_pyramid image into the textures array. make it manage all textures, and let stuff just hold onto a handle inside that array.
    // @study does this setup allow us to add more textures as needed and leave slots empty in the mean time?
    // @study how many textures can we index into like this? is there a limit defined by the gpu?
    depth_descriptor_set_layout := create_descriptor_set_layout(gpu.device, depth_reduce_shader)
    defer_destroy(vk.DestroyDescriptorSetLayout, depth_descriptor_set_layout)
    
    ////////////////////////////////////////////////
    
    stats_pool: vk.QueryPool
    stats_count: u32
    {
        stats_bits := vk.QueryPipelineStatisticFlags {
            .FRAGMENT_SHADER_INVOCATIONS,
            .COMPUTE_SHADER_INVOCATIONS,
            .TASK_SHADER_INVOCATIONS_EXT,
            .MESH_SHADER_INVOCATIONS_EXT,
        }
        stats_count = cast(u32) card(stats_bits)
        StatsSize :: 1
        create_info := vk.QueryPoolCreateInfo {
            sType = .QUERY_POOL_CREATE_INFO,
            queryType          = .PIPELINE_STATISTICS,
            pipelineStatistics = stats_bits,
            queryCount         = stats_count,
        }
        check(vk.CreateQueryPool(gpu.device, &create_info, nil, &stats_pool))
        defer_destroy(vk.DestroyQueryPool, stats_pool)
    }
    
    ////////////////////////////////////////////////
    
    cull_pipeline:    Pipeline
    depth_pipeline:   Pipeline
    meshlet_pipeline: Pipeline
    
    ////////////////////////////////////////////////
    
    next_frame: u64 = MaxFramesInFlight
    frame_semaphore := gpu_create_timeline_semaphore(&gpu, MaxFramesInFlight)
    defer_destroy(vk.DestroySemaphore, frame_semaphore)
    
    ////////////////////////////////////////////////
    
    draw_globals: Draw_Globals
    
    for &pos, index in draw_globals.light_pos {
        t := clamp_01_to_range(cast(f32) 0, cast(f32) len(draw_globals.light_pos), cast(f32) index)
        pos.xyz = v3{0, -10, 10}
        pos.xz += arm(t * Tau)
    }
    
    
    cam_pos := v3{ 0, 0, 0}
    object_rotation: v3
    quit: bool
    last_time := time.tick_now()
    
    // @cleanup into a debug struct
    culling_enabled: bool = true
    lod_enabled:     bool = true
    display_pyramid: bool
    display_pyramid_mip_level: i32 = 0
    
    // @correctness ensure that this is enough and that we did not overflow inside of a frame and override someone elses data for a shader
    frame_bump_allocators: [MaxFramesInFlight] Bump_Allocator
    for &bump in frame_bump_allocators {
        bump = bump_allocator_make_temporary(&gpu, 1 * Megabyte)
    }
    
    cull_delta: f64
    cpu_time: f64
    gpu_time: f64
    for !quit {
        free_all(context.temp_allocator)
        
        ////////////////////////////////////////////////
        
        // @speed similarly the timestamps should only be collected if we need them. As we currently only look at the last rendered frame, we should only take them if we then also print them. In the future we may want to store more than one frame, but for now this would be better.
        print_profile_and_stats: bool
        
        mouse_delta: v2
        mouse_wheel_delta: f32
        @(static) left_down: bool
        @(static) space_down: bool
        
        window_event_begin := time.tick_now()
        for event: sdl.Event; sdl.PollEvent(&event); {
            #partial switch event.type {
            case .QUIT:
                quit = true
            
            case .MOUSE_MOTION:
                mouse_delta = { event.motion.xrel, event.motion.yrel }
            case .MOUSE_BUTTON_DOWN:
                if event.button.button == sdl.BUTTON_LEFT {
                    left_down = true
                }
            case .MOUSE_BUTTON_UP:
                if event.button.button == sdl.BUTTON_LEFT {
                    left_down = false
                }
            case .KEY_DOWN:
                switch event.key.key {
                case sdl.K_SPACE: space_down = true
                case sdl.K_C:     culling_enabled = !culling_enabled
                case sdl.K_L:     lod_enabled     = !lod_enabled
                case sdl.K_O:     display_pyramid = !display_pyramid
                case sdl.K_PLUS:  display_pyramid_mip_level = clamp(display_pyramid_mip_level+1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                case sdl.K_MINUS: display_pyramid_mip_level = clamp(display_pyramid_mip_level-1, 0, cast(i32) len(stuff.depth_pyramid_mips)-1)
                case sdl.K_P:     print_profile_and_stats = true
                }
            case .KEY_UP:
                if event.key.key == sdl.K_SPACE {
                    space_down = false
                }
                
            case .MOUSE_WHEEL:
                mouse_wheel_delta = event.wheel.y
                
            case .WINDOW_RESIZED:
                gpu.should_recreate_swapchain = true
            }
        }
        
        window_event_delta := time.tick_since(window_event_begin)
        
        ////////////////////////////////////////////////
        
        // Though we do not track the time, *we* take to handle the input, we also exclude all time taken by sdl and windows(which may block) with this
        current_time  := time.tick_now()
        delta_tick    := time.tick_diff(last_time, current_time)
        delta_tick    -= window_event_delta
        
        delta_time_64 := time.duration_seconds(delta_tick)
        delta_time := cast(f32) delta_time_64
        last_time = current_time
        
        if mouse_wheel_delta != 0 {
            cam_pos.z += mouse_wheel_delta * -10 * delta_time
        }
        
        if mouse_delta != 0 && left_down {
            if space_down {
                cam_pos.xy += mouse_delta * {-1, 1} * delta_time * 5
            } else {
                object_rotation.yx += mouse_delta * delta_time
            }
        }
        
        ////////////////////////////////////////////////
        
        // @todo(viktor): if the window is minimized we can never get it back up and visible
        if gpu.should_recreate_swapchain {
            gpu.should_recreate_swapchain = false
            
            vk.DeviceWaitIdle(gpu.device)
            recreate_swapchain(&gpu, sdl_get_window_size(window))
            recreate_stuff(&gpu, &stuff)
        }
        
        watchers_check_for_modification(watchers)
        
        // @api should this be begin pipeline, which just always takes in the dependencies and does a reload and recreate itself?
        if reload_shaders_if_needed(watchers, shader_allocator, &draw_cull_shader) || !pipeline_is_valid(cull_pipeline) {
            cull_pipeline = gpu_create_compute_pipeline(&gpu, draw_cull_shader, ^Cull_Globals, cull_pipeline)
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, &depth_reduce_shader) || !pipeline_is_valid(depth_pipeline) {
            depth_pipeline = create_compute_pipeline(&gpu, depth_reduce_shader, depth_descriptor_set_layout, ^Depth_Globals, depth_pipeline)
        }
        
        if reload_shaders_if_needed(watchers, shader_allocator, meshlet_shaders[:]) || !pipeline_is_valid(meshlet_pipeline) {
            meshlet_pipeline = create_graphics_pipeline(&gpu, { textures_descriptor_set_layout }, meshlet_shaders[:], ^Draw_Globals, meshlet_pipeline)
        }
        
        ////////////////////////////////////////////////
        
        gpu_wait_semaphore(&gpu, frame_semaphore, next_frame + 1 - MaxFramesInFlight)
        frame_index, restart := get_the_next_frame(&gpu, frame_semaphore)
        if restart { continue }
        
        bump := &frame_bump_allocators[frame_index]
        
        ////////////////////////////////////////////////
        
        entropy := seed_random_series(54654)
        when true {
            @(static) draws: [20000] Draw
            global_rotation := la.quaternion_from_euler_angles_f32(expand_values(object_rotation * random_unilateral(&entropy, v3)), .XYX)
            for &draw in draws {
                p := random_bilateral(&entropy, v3) * {10, 10, 10} - {0, 0, 20}
                
                draw.p           = p
                draw.scale       = linear_blend(cast(f32) .1, .4, square(random_unilateral(&entropy, f32))) / 2
                rotation        := la.quaternion_angle_axis(random_unilateral(&entropy, f32) * Tau, random_bilateral(&entropy, v3))
                draw.orientation = rotation * global_rotation
                
                draw.texture_index = random_index(&entropy, textures[:])
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        } else {
            @(static) draws: [1] Draw
            for &draw in draws {
                p := v3{0, 0, -3}
                
                draw.p           = p
                draw.scale       = 1
                draw.orientation = 0
                
                draw.texture_index = 2
                
                mesh, mesh_index := random_choice_index(&entropy, geometry.meshes[:])
                
                draw.mesh_index    = mesh_index
                draw.vertex_offset = mesh.vertex_offset
            }
        }
        
        copy(db_view, draws[:])
        
        ////////////////////////////////////////////////
        
        cpu_time = time_smoothed_blend(delta_time_64, cpu_time, delta_time_64)
        
        {
            view :: proc (seconds: f64) -> time.Duration {
                return time.duration_round(cast(time.Duration) (seconds * cast(f64) time.Second), 1 * time.Microsecond)
            }
            
            extra: string
            if display_pyramid {
                extra = fmt.tprintf(", displaying depth mip level %v", display_pyramid_mip_level)
            }
            title := fmt.ctprintf("cpu time: %.3v, gpu time: %.3v, cull time: %.3v, culling %v, level of detail %v%v",
                view(cpu_time), 
                view(gpu_time), 
                view(cull_delta), 
                culling_enabled ? "on" : "off",
                lod_enabled     ? "on" : "off",
                extra
            )
            // @todo(viktor): how can we record how many triangles we have rendered after culling?
            sdl.SetWindowTitle(window, title)
        }
        
        ////////////////////////////////////////////////
        
        check(vk.ResetCommandPool(gpu.device, gpu.command_pools[frame_index], {}))
        // @api expecting the user to pass the frame index is a source for mistakes
        cmd := gpu_begin_command_recording(&gpu, frame_index, gpu.queue)
        
        gpu_profile_frame_begin(gpu.device, cmd)
        
        ////////////////////////////////////////////////
        
        gpu_labeled_region_begin(cmd, "culling", {0.0, 0.6, 0.8, 1.0})
            gpu_profile_zone_begin("culling")
            
            // @todo(viktor): is this barrier/transition before the fill necessary?
            gpu_barrier(cmd, {}, { .TRANSFER })
            
            ////////////////////////////////////////////////
            
            vk.CmdFillBuffer(cmd, draw_command_count_buffer_buffer, 0, size_of(dccb_view^), 0)
            
            ////////////////////////////////////////////////
            
            // :OcclusionCull: the memory barrier for the depth pyramid had a parameters, but just for the late pass (see https://youtu.be/Ka30T6BMdhI?list=PLOU0IFZHP8dDap0WO7_IwOzgITq3ZUZsy&t=10157)
            gpu_barrier(cmd, { .DRAW_INDIRECT, .MESH_SHADER_EXT, .TRANSFER }, { .COMPUTE_SHADER })
            
            ////////////////////////////////////////////////
            
            // @important @todo once we are satisfied with the occlusion culling the near plane should be set to a more reasonable value like 0.01. the 0.1 value is just useful for debugging, as the depth values lie in a more visible range.
            projection := projection_reversed_z_infinite_far_plane(70 * RadPerDeg, cast(f32) gpu.swapchain_size.x / cast(f32) gpu.swapchain_size.y, 0.1)
            view       := translate(1, -cam_pos)
            
            draw_distance: f32 = 100
            
            frustum_planes: [6] v4
            if culling_enabled {
                view_projection := projection * view
                cam_forward := v3{0, 0, -1}
                
                frustum_planes[0] = get_row_v4(view_projection, 3) + get_row_v4(view_projection, 0) // x + w < 0
                frustum_planes[1] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 0) // x - w > 0
                frustum_planes[2] = get_row_v4(view_projection, 3) + get_row_v4(view_projection, 1) // y + w < 0
                frustum_planes[3] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 1) // y - w > 0
                frustum_planes[4] = get_row_v4(view_projection, 3) - get_row_v4(view_projection, 2) // z - w > 0 -- :ReversedZ:
                // @todo(viktor): also reenable in the compute shader
                // frustum_planes[5] = v4{**cam_forward, draw_distance + dot(cam_forward, cam_pos)}          // :ReversedZ: infinite far plane
                
                for &plane in frustum_planes {
                    plane /= length(plane.xyz)
                }
            }
            
            
            cull_globals_cpu, cull_globals_gpu := bump_allocate_type(bump, Cull_Globals)
            
            cull_globals_cpu^ = Cull_Globals {
                frustum_planes      = frustum_planes,
                draw_buffer         = draw_buffer,
                mesh_buffer         = mesh_buffer,
                draw_command_buffer = draw_command_buffer,
                draw_command_count  = draw_command_count_buffer.address,
                
                lod_enabled             = cast(b32) lod_enabled,
                frustum_culling_enabled = cast(b32) culling_enabled,
                draw_count              = len(draws),
                camera_p                = cam_pos,
            }
            
            gpu_set_pipeline(cmd, cull_pipeline)
            
                // @shader cull.comp
                gpu_dispatch(cmd, &cull_globals_gpu, get_group_count(draw_cull_shader, len(draws)))
            
            ////////////////////////////////////////////////
            
            // @todo(viktor): should these be combined into one api call?
            gpu_barrier(cmd, { .COMPUTE_SHADER }, { .DRAW_INDIRECT })
            // this apparently needs to happend before we do anything related to rendering
            pipeline_barrier_begin()
                add_image_barrier(&gpu.color_buffer, { .BOTTOM_OF_PIPE }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .COLOR_ATTACHMENT_WRITE },         .ATTACHMENT_OPTIMAL)
                add_image_barrier(&gpu.depth_buffer, { .BOTTOM_OF_PIPE }, {}, .UNDEFINED, { .COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, { .DEPTH }) // :Stencil: add .STENCIL to the aspect mask
            pipeline_barrier_end(cmd)
            
            ////////////////////////////////////////////////
            
            gpu_profile_zone_end()
        gpu_labeled_region_end(cmd)
        
        ////////////////////////////////////////////////
        // Setting these outside of rendering-sections means they persist across all sections.
        vk.CmdSetViewport(cmd, 0, 1, &vk.Viewport {
            x      = 0,
            y      = 0,
            width  = cast(f32) gpu.swapchain_size.x,
            height = cast(f32) gpu.swapchain_size.y,
            minDepth = 0,
            maxDepth = 1,
        })
        
        vk.CmdSetScissor(cmd, 0, 1, &vk.Rect2D { extent = { **gpu.swapchain_size } })
        
        ////////////////////////////////////////////////
        
        // @shaders meshlet pipeline
        draw_globals.projection = projection
        draw_globals.view       = view
        
        draw_globals.draw_command_buffer = draw_command_buffer
        draw_globals.draw_buffer         = draw_buffer
        draw_globals.mesh_buffer         = mesh_buffer
        draw_globals.meshlet_buffer      = meshlet_buffer
        draw_globals.meshlet_data_buffer = meshlet_data_buffer
        draw_globals.vertex_buffer       = vertex_buffer
        
        draw_globals_cpu, draw_globals_gpu := bump_allocate_type(bump, Draw_Globals)
        draw_globals_cpu^ = draw_globals
        
        gpu_profile_zone_begin("rendering early pass")
        gpu_labeled_region_begin(cmd, "rendering early pass", {0.6, 0.1, 07, 1.0})
        begin_rendering(cmd, &gpu, {0.07, 0.07, 0.07, 1}, early = true)
                
            if print_profile_and_stats {
                vk.ResetQueryPool(gpu.device, stats_pool, 0, stats_count)
                vk.CmdBeginQuery(cmd, stats_pool, 0, {})
            }
            
            gpu_labeled_region_begin(cmd, "meshlets", {0.0, 0.6, 0.8, 1.0})
            gpu_profile_zone_begin("meshlets")
            
            gpu_set_pipeline(cmd, meshlet_pipeline)
                // @shader meshlet.task meshlet.mesh meshlet.frag
                vk.CmdBindDescriptorSets(cmd, meshlet_pipeline.bind_point, meshlet_pipeline.layout, 0, 1, &textures_descriptor_set, 0, nil)
                
                vk.CmdPushConstants(cmd, meshlet_pipeline.layout, meshlet_pipeline.shader_stages, 0, size_of(vk.DeviceAddress), &draw_globals_gpu)
                
                // @todo(viktor): as nice as the api could be this is a bit stupid
                vk.CmdDrawMeshTasksIndirectCountEXT(cmd, draw_command_buffer_buffer, auto_cast offset_of(Draw_Command, command), draw_command_count_buffer_buffer, 0, len(draws), size_of(Draw_Command))
            
            gpu_profile_zone_end()
            gpu_labeled_region_end(cmd)
            
            if print_profile_and_stats {
                vk.CmdEndQuery(cmd, stats_pool, 0)
            }
            
        end_rendering(cmd)
        gpu_labeled_region_end(cmd)
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        // :OcclusionCull: the barrier before the depth pyramid was missing the barrier for the pyramid.image itself (see https://youtu.be/Ka30T6BMdhI?list=PLOU0IFZHP8dDap0WO7_IwOzgITq3ZUZsy&t=11592)
        
        pipeline_barrier_begin()
            add_image_barrier_transition_from_last(&gpu.depth_buffer, { .COMPUTE_SHADER }, { .SHADER_READ }, .SHADER_READ_ONLY_OPTIMAL, { .DEPTH })
            add_image_barrier(&stuff.depth_pyramid, {}, {}, .UNDEFINED,  { .COMPUTE_SHADER }, { .SHADER_WRITE }, .GENERAL)
        pipeline_barrier_end(cmd)
        
        ////////////////////////////////////////////////
        
        gpu_profile_zone_begin("depth pyramid building")
        gpu_labeled_region_begin(cmd, "depth pyramid building", {0.4, 0.8, 0, 1.0})
        
        gpu_set_pipeline(cmd, depth_pipeline)
            
            updates: [dynamic; 32] DescriptorUpdateData
            prev_mip: ^Depth_Pyramid_Mip
            for &mip, mip_level in stuff.depth_pyramid_mips {
                // @shaders depth_reduce.comp
                
                clear(&updates)
                append(&updates, DescriptorUpdateData { image = { 
                    stuff.depth_sampler,
                    mip_level == 0 ? gpu.depth_buffer.view                   : prev_mip.view,
                    mip_level == 0 ? gpu.depth_buffer.last_transition.layout : .GENERAL,
                } })
                append(&updates, DescriptorUpdateData { image = { stuff.depth_sampler, mip.view, .GENERAL } })
                vk.CmdPushDescriptorSetWithTemplate(cmd, depth_pipeline.update_template, depth_pipeline.layout, 0, raw_data(&updates))
                
                prev_mip = &mip
                
                depth_globals_cpu, depth_globals_gpu := bump_allocate_type(bump, Depth_Globals)
                depth_globals_cpu^ = Depth_Globals { size = cast(v2) mip.size }
                
                gpu_dispatch(cmd, &depth_globals_gpu, get_group_count(depth_reduce_shader, **mip.size))
                
                pipeline_barrier_begin()
                    add_image_barrier_transition_from_last(&stuff.depth_pyramid, { .COMPUTE_SHADER }, { .SHADER_READ }, .GENERAL)
                pipeline_barrier_end(cmd, { .BY_REGION })
            }
        
        gpu_labeled_region_end(cmd)
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        pipeline_barrier_begin()
            add_image_barrier_transition_from_last(&gpu.depth_buffer, {.EARLY_FRAGMENT_TESTS }, { .DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE }, .ATTACHMENT_OPTIMAL, { .DEPTH })
        pipeline_barrier_end(cmd)
        
        ////////////////////////////////////////////////
        
        gpu_profile_zone_begin("rendering late pass")
        gpu_labeled_region_begin(cmd, "rendering late pass", {0.6, 0.1, 07, 1.0})
        begin_rendering(cmd, &gpu, {}, early = false)
            
        end_rendering(cmd)
        gpu_labeled_region_end(cmd)
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        gpu_profile_zone_begin("copy to swapchain")
        
            pipeline_barrier_begin()
                add_image_barrier(&gpu.swapchain_images[gpu.image_index], { .COLOR_ATTACHMENT_OUTPUT }, {}, .UNDEFINED, { .TRANSFER }, { .TRANSFER_WRITE }, .TRANSFER_DST_OPTIMAL)
                if !display_pyramid {
                    add_image_barrier_transition_from_last(&gpu.color_buffer, { .TRANSFER }, { .TRANSFER_READ }, .TRANSFER_SRC_OPTIMAL)
                } else {
                    add_image_barrier_transition_from_last(&stuff.depth_pyramid, { .TRANSFER }, { .TRANSFER_READ }, .TRANSFER_SRC_OPTIMAL)
                }
            pipeline_barrier_end(cmd)
                
            destination := gpu.swapchain_images[gpu.image_index]
            if !display_pyramid {
                source := gpu.color_buffer
                
                vk.CmdCopyImage(cmd, source.image, source.last_transition.layout, destination.image, destination.last_transition.layout, 1, &vk.ImageCopy {
                    srcSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    extent         = { gpu.swapchain_size.x, gpu.swapchain_size.y, 1 },
                })
            } else {
                source := stuff.depth_pyramid
                
                mip_size  := cast(iv2) stuff.depth_pyramid_mips[display_pyramid_mip_level].size
                dest_size := cast(iv2) gpu.swapchain_size
                
                vk.CmdBlitImage(cmd, source.image, source.last_transition.layout, destination.image, destination.last_transition.layout, 1, &vk.ImageBlit {
                    srcSubresource = { aspectMask = { .COLOR }, layerCount = 1, mipLevel = cast(u32) display_pyramid_mip_level },
                    dstSubresource = { aspectMask = { .COLOR }, layerCount = 1 },
                    srcOffsets = { {0, 0, 0}, {mip_size.x, mip_size.y,   1}},
                    dstOffsets = { {0, 0, 0}, {dest_size.x, dest_size.y, 1}},
                }, .NEAREST)
            }
            
            pipeline_barrier_begin()
                add_image_barrier_transition_from_last(&gpu.swapchain_images[gpu.image_index], {}, {}, .PRESENT_SRC_KHR)
            pipeline_barrier_end(cmd)
        
        gpu_profile_zone_end()
        
        ////////////////////////////////////////////////
        
        gpu_profile_frame_end()
        
        check(vk.EndCommandBuffer(cmd))
        
        ////////////////////////////////////////////////
        
        // @cleanup dont pass the frameindex, this is a place that could cause mistakes
        next_frame += 1
        gpu_end_the_command_buffer_and_submit_and_present_the_queue(&gpu, frame_semaphore, next_frame, frame_index, &cmd)
        
        gpu_profile_collate_times(&gpu, gpu.device, print_profile_and_stats)
        
        gpu_delta  := gpu_profile_get_zone("frame").total_time_with_children
        cull_delta  = gpu_profile_get_zone("culling").total_time
        // this might have happened when a validation error occurred, causing the smooth value to be messed for a very long time
        if gpu_delta >= 0 {
            gpu_time = time_smoothed_blend(delta_time_64, gpu_time, gpu_delta)
        }
        
        ////////////////////////////////////////////////
        
        if print_profile_and_stats {
            stats_result: [128] u64
            size := cast(int) size_of_slice(stats_result[:])
            query_result := vk.GetQueryPoolResults(gpu.device, stats_pool, 0, 1, size, &stats_result[0], size_of(stats_result[0]), { ._64, .WAIT })
            check(query_result)
            
            fmt.println("------------------------------------\nStats:")
            bits := [?] vk.QueryPipelineStatisticFlag {
                .COMPUTE_SHADER_INVOCATIONS,
                .TASK_SHADER_INVOCATIONS_EXT,
                .MESH_SHADER_INVOCATIONS_EXT,
                .FRAGMENT_SHADER_INVOCATIONS,
            }
            
            for bit, index in bits {
                fmt.printfln("  %v = %v", bit, view_magnitude(stats_result[index]))
            }
            fmt.printfln("-------------------------------------")
        }
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
	check(vk.DeviceWaitIdle(gpu.device))
    
    gpu_free(&gpu, vertex_buffer)
    gpu_free(&gpu, meshlet_buffer)
    gpu_free(&gpu, meshlet_data_buffer)
    gpu_free(&gpu, mesh_buffer)
    gpu_free(&gpu, draw_buffer)
    gpu_free(&gpu, draw_command_buffer)
    gpu_free(&gpu, draw_command_count_buffer)
    
    for &bump in frame_bump_allocators {
        bump_allocator_delete(&gpu, &bump)
    }
    
    destroy_pipeline(gpu.device, meshlet_pipeline)
    destroy_pipeline(gpu.device, cull_pipeline)
    destroy_pipeline(gpu.device, depth_pipeline)
    
    for texture in textures {
        gpu_delete(&gpu, texture)
    }
    
    delete_stuff(&gpu, &stuff, final = true)
    
    gpu_deinit(&gpu)
}

////////////////////////////////////////////////

delete_stuff :: proc (gpu: ^Gpu, stuff: ^Stuff_With_The_Same_Lifetime_As_The_Swapchain, final := false) {
    gpu_delete(gpu, stuff.depth_pyramid)
    
    for &it in stuff.depth_pyramid_mips {
        vk.DestroyImageView(gpu.device, it.view, nil)
    }
    clear(&stuff.depth_pyramid_mips)
    
    if final {
        vk.DestroySampler(gpu.device, stuff.depth_sampler, nil)
    }
}

recreate_stuff :: proc (gpu: ^Gpu, stuff: ^Stuff_With_The_Same_Lifetime_As_The_Swapchain) {
    delete_stuff(gpu, stuff)
    
    if stuff.depth_sampler == 0 {
        stuff.depth_sampler = create_sampler(gpu.device, .NEAREST, .NEAREST)
    }
    
    // Ensures that all reductions are at most 2x2 which makes sure they are conservative.
    pyramid_size := uv2{previous_power_of_two(gpu.swapchain_size.x), previous_power_of_two(gpu.swapchain_size.y)} 
    // Each mip level is a quarter of the size of the previous, as we half both dimensions each time.
    mip_count := 1 + max(integer_log2(pyramid_size.x), integer_log2(pyramid_size.y))
    
    // @waste this makes an image view over all mips, which we never use. its creation could be skipped. the aspect mask parameter is only relevant when in image view is requested.
    stuff.depth_pyramid = gpu_make_image(gpu, pyramid_size, .R32_SFLOAT, { .SAMPLED, .STORAGE, .TRANSFER_SRC }, { .COLOR }, mip_levels = mip_count)
    
    for i in 0..<mip_count {
        mip := append_into(&stuff.depth_pyramid_mips)
        mip.view = create_image_view(gpu.device, stuff.depth_pyramid, i, 1, { .COLOR })
        mip.size = pyramid_size
        mip.size.x >>= i
        mip.size.y >>= i
        mip.size = vec_max(mip.size, 1)
    }
}

////////////////////////////////////////////////

sdl_get_window_size :: proc (window: ^sdl.Window) -> uv2 {
    result: iv2
    sdl.GetWindowSize(window, &result.x, &result.y)
    return cast(uv2) result
}

////////////////////////////////////////////////

check :: proc { check_vulkan, check_sdl, check_ktx }
check_vulkan :: proc (result: vk.Result, loc := #caller_location) {
    if result != .SUCCESS {
        fmt.printf("%v:%v:%v: Vulkan call returned %v", loc.file_path, loc.line, loc.column, result)
        intrinsics.debug_trap()
    }
}
check_sdl :: proc (result: bool, loc := #caller_location) {
    if !result {
        fmt.printf("%v:%v:%v: SDL call returned %v", loc.file_path, loc.line, loc.column, sdl.GetError())
        intrinsics.debug_trap()
        os.exit(1)
    }
}