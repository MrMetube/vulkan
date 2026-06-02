package build

optimize :: false
pedantic :: false

main :: proc () {
    init_build(run_from_data = true, wait = true)
    
    parse_run_and_debug_arguments()
    
    if begin_build(cmd, "code", "engine.exe", .Kill) {
        build_meander()
        
        build_optimizations(optimize)
        build_native()
        build_pedantic(pedantic)
        append(cmd, "-collection:lib=libs")
        if false {
            append(cmd, "-vet-packages:main", "-vet-unused-procedures")
        }
        
        end_build(cmd)
    }
    
    run_or_debug_according_to_args()
}