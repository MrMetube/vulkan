# Modern Vulkan Engine
A Vulkan 1.4 Engine written in Odin language, that defines itself by:
- using modern task and mesh shaders with meshlet rendering, which replaces the old vertex (, tesselation and geometry) shaders
    - this allows us to do per meshlet culling, when a meshlet is facing backwards towards the camera
- renders everything with one draw call by using a indirect Multidraw command
- aiming to be bindless, by using descriptor indexing
- making use of dynamic rendering and therefore not using render passes, which did not turn out to be of value

It originally followed [How to Vulkan in 2026](https://www.howtovulkan.com/) and also took inspiration from the [niagara project](https://youtube.com/playlist?list=PL0JVLUVCkk-l7CWCn3-cdftR0oajugYvd&si=OShHwX8FKuxmsHJe) by Arseny Kapoulkine aka. Zeux.

## Dependencies
- [Tiny OBJ Loader](https://github.com/Capati/odin-tobj)
- [Odin Bindings for KTX](https://github.com/nowhereware/ktx_odin)
- [Odin Bindings for Meshoptimizer](https://github.com/GloriousPtr/odin-meshoptimizer)
