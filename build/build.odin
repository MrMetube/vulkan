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
    
    // @copypasta from code.main: shader setup code
    code.generate_shader_api("data/shaders/api.generated.glsl")
    
    shaders: [dynamic] string
    get_all_files_with_extension(&shaders, "data/shaders", context.temp_allocator, ".frag", ".mesh", ".task", ".comp")
    
    any_shader_had_errors: bool
    for shader in shaders {
        // @copypasta from code.compile_and_load_shader
        output_directory := "build"
        input_directory, input_file := os.split_path(shader)
        
        output_path, _ := os.join_path({input_directory, output_directory, input_file}, context.temp_allocator)
        output_extension := ".spv"
        shader_output := fmt.tprintf("%v%v", output_path, output_extension)
        
        code.compile_shader_begin(cmd, shader_output)
        
        ok := code.compile_shader_end(cmd, shader)
        if !ok { any_shader_had_errors = true }
    }
    
    if strict_shaders && any_shader_had_errors {
        fmt.printfln("\nFailed to compile shaders. Stopping build process.")
        return
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