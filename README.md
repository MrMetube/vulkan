# Modern Vulkan Engine
A Vulkan 1.4 Engine written in Odin language, that defines itself by:
- using modern mesh shaders with meshlet rendering, which replaces the old vertex (, tesselation and geometry) shaders
    - this allows us to do per meshlet culling, when a meshlet is facing backwards towards the camera
- renders everything with one draw call by using a indirect Multidraw command
- aiming to be bindless, by using descriptor indexing
- making use of dynamic rendering and therefore not using render passes, which did not turn out to be of value
- @todo well that didnt work out: using the modern shader language Slang

It originally followed [How to Vulkan in 2026](https://www.howtovulkan.com/)

## Dependencies
- [Tiny OBJ Loader](https://github.com/Capati/odin-tobj)
<!-- - [Odin Bindings for VMA](https://github.com/Capati/odin-vma)
  - [Prebuild lib for Windows](https://capati.github.io/odin-vk-guide/project-setup/building-project/#pre-compiled-binaries-for-windows) -->
- [Odin Bindings for KTX](https://github.com/nowhereware/ktx_odin)
- [Odin Bindings for Meshoptimizer](https://github.com/GloriousPtr/odin-meshoptimizer)
<!-- @todo remove - [Odin Bindings for slang](https://github.com/DragosPopse/odin-slang) -->
