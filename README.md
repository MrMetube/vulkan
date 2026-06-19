# Modern Vulkan Engine
A Vulkan 1.4 Engine written in Odin language, that defines itself by:
- using modern task and mesh shaders with meshlet rendering, which replaces the old vertex (, tesselation and geometry) shaders
    - this allows us to do per meshlet culling, when a meshlet is facing backwards towards the camera
- renders everything with one draw call by using a indirect Multidraw command
- aiming to be bindless, by using descriptor indexing
- making use of dynamic rendering, which is simpler and replaces render passes

It originally followed [How to Vulkan in 2026](https://www.howtovulkan.com/) and also took inspiration from the [niagara project](https://youtube.com/playlist?list=PL0JVLUVCkk-l7CWCn3-cdftR0oajugYvd&si=OShHwX8FKuxmsHJe) by Arseny Kapoulkine aka. Zeux.

## Overview

### Meshlets
Meshes are subdivided into meshlets: smaller groups of triangles of the mesh
![An example mesh with its meshlets highlighted](./notes/meshlet_comparison.png)
Here each group is visualized with a different color.

### Level of Detail
Multiple levels of detail are generated per mesh. The decision of which LOD to use can be based on the distance to the camera.

![A visualization of the levels of detail of a mesh.](./notes/compute_lod.gif)  
The further the camera is from the mesh, the fewer meshlets and therefore triangles are used to draw it. The reduces the work for the gpu. The distances should be tuned, so that the visual impact of switching to a lower level of detail is minimal.

## Dependencies
The dependencies are not commited into this repository. You can find them through these links:
- [Tiny OBJ Loader](https://github.com/Capati/odin-tobj): used to parse and load the mesh data from Wavefront files.

- [Odin Bindings for LibKTX](https://github.com/nowhereware/ktx_odin): used to load KTX textures. (Note: these are bindings to the original library, which has a C api.)
- [Odin Bindings for Meshoptimizer](https://github.com/GloriousPtr/odin-meshoptimizer): used to generate the meshlets and LOD data from the mesh. (Note: these are bindings to the original library, which has a C api.)