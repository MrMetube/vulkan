# To Do
- do a depth prepass where we only render into the depthbuffer
  - then do a second pass, where depthtest is set to Equal, in which we compute the color
- rewatch on bindless https://youtu.be/bPzpz2d0ins?t=11594  
- rewatch on memory allocation https://youtu.be/Ju4rXct6mPI?t=9813

## Legacy
Taken from this page https://docs.vulkan.org/spec/latest/appendices/legacy.html.


### Render Pass Objects: Superseded via dynamic rendering

VK_KHR_dynamic_rendering and Vulkan 1.3 added a new way to specify render passes without needing to create VkFramebuffer and VkRenderPass objects. However, subpass functionality had no equivalent, meaning dynamic rendering was only suitable as a substitute for content not using subpasses.

VK_KHR_dynamic_rendering_local_read and Vulkan 1.4 later allowed the expression of most subpass functionality in core or extensions. Any subpass functionality which was not replicated is still expressible but requires applications to split work over multiple dynamic render pass instances. Functionality not covered with local reads would result in most or all vendors splitting the subpass internally.
	
Outside of vendor extensions, applications are advised to make use of vkCmdBeginRendering and vkCmdEndRendering to manage render passes from this API version onward.


### Sampler and Buffer View Objects: Unnecessary with Descriptor Heaps

When using descriptor heaps, the creation of sampler and buffer view objects are wholly unnecessary. Instead, these objects are directly converted to descriptors via vkWriteSamplerDescriptorsEXT and vkWriteResourceDescriptorsEXT, skipping the need to create objects altogether. In the case of samplers, samplers can also be embedded directly into a shader via [shader bindings](https://docs.vulkan.org/spec/latest/chapters/descriptorheaps.html#descriptorheaps-bindings), which only requires the VkSamplerCreateInfo, rather than a created object.

The creation of image views can also be skipped similarly for images used as descriptors, but image views themselves are still used elsewhere in the spec, such as for render passes.


### Descriptor Management: Replaced by descriptor Heaps

[Descriptor heaps](https://docs.vulkan.org/spec/latest/chapters/descriptorheaps.html#descriptorheaps) provide a complete alternative for managing shader resources, and can be used where present instead of the resource management provided by Vulkan 1.0. Descriptor heaps can similarly be used instead of VK_EXT_descriptor_buffer.

While it is possible to use a mix of these in the same application, they cannot be used at the same time, and there are potential performance penalties for switching on some implementations.


### Buffer Commands: Superseded by device address commands

Most commands that previously took buffer objects, including all command buffer commands, have now been superseded by equivalent commands or structures that use [VkDeviceAddressRangeKHR](https://docs.vulkan.org/spec/latest/chapters/fundamentals.html#VkDeviceAddressRangeKHR) structures to specify the address range directly. Some of these need a little additional information from the application in the form of VkAddressCommandFlagBitsKHR, which previously would have been retrieved from the buffer object itself.

## Guide 
- [dynamic state](https://github.com/KhronosGroup/Vulkan-Guide/blob/main/chapters/dynamic_state_map.adoc)
- [synchronization2](https://github.com/KhronosGroup/Vulkan-Guide/blob/main/chapters/extensions/VK_KHR_synchronization2.adoc)
- [device generated commands](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_device_generated_commands.html)