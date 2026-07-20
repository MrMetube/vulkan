package build

import "core:os"
import "core:fmt"
import "../code" // just for the shader compiling

optimize       :: false
pedantic       :: false
strict_shaders :: true

main :: proc () {
    init_build(run_from_data = true)
    
    parse_run_and_debug_arguments()
    
    fmt.printfln("\nCompiling shaders:")
    // @copypasta from code.main: shader setup code
    code.generate_shader_api("data/shaders/api.generated.glsl")
    
    shaders: [dynamic] string
    get_all_files_with_extension(&shaders, "data/shaders", context.temp_allocator, ".frag", ".vert", ".mesh", ".task", ".comp")
    
    for shader in shaders {
        // @copypasta from code.compile_and_load_shader
        output_directory := "build"
        input_directory, input_file := os.split_path(shader)
        
        output_path, _ := os.join_path({input_directory, output_directory, input_file}, context.temp_allocator)
        output_extension := ".spv"
        shader_output := fmt.tprintf("%v%v", output_path, output_extension)
        
        code.compile_shader_begin(cmd, shader_output)
        
        append(cmd, shader)
        
        ok: bool
        if !run_command(cmd, or_exit = false, stdout = os.stdout, stderr = os.stderr, async = procs) {
            fmt.eprintfln("Failed to run command to compile shader '%v'")
        }
    }
    
    if strict_shaders {
        success := true
        states: [dynamic] os.Process_State
        for p, index in procs {
            state, _ := os.process_wait(p)
            append(&states, state)
        }
        
        for state, index in states {
            if state.exit_code != 0 {
                if success { fmt.printfln("") }
                success = false
                fmt.printfln("Error: Failed to compile %v:", shaders[index])
            }
        }
        
        if !success {
            fmt.printfln("\nFailed to compile shaders. Stopping build process.")
            os.exit(1)
        }
        
        fmt.printfln("\nAll shaders compiled.\n")
    }
    
    if begin_build(cmd, "code", "engine.exe", .Kill) {
        build_meander()
        
        build_optimizations(optimize)
        build_native()
        build_pedantic(pedantic)
        if false && pedantic {
            append(cmd, "-vet-packages:main", "-vet-unused-procedures")
        }
        
        end_build(cmd)
    }
    
    run_or_debug_according_to_args()
}