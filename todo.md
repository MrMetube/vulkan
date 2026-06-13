# To Do
- do a depth prepass where we only render into the depthbuffer
  - then do a second pass, where depthtest is set to Equal, in which we compute the color
  
## Legay
Taken from this page https://docs.vulkan.org/spec/latest/appendices/legacy.html.

### Physical Device Queries: Superseded via version 2

VK_KHR_get_physical_device_properties2 was incorporated into Vulkan 1.1, which introduced new versions of several physical device query functions. These provide the same functionality as the Vulkan 1.0 functionality but with greater extensibility.

When querying device features, vkGetPhysicalDeviceFeatures2 should be used instead of vkGetPhysicalDeviceFeatures. When enabling device features, VkPhysicalDeviceFeatures2 should be provided in the pNext chain of VkDeviceCreateInfo instead of using VkDeviceCreateInfo::pEnabledFeatures.

### Version Macros: Superseded via replacements including API variant

The version macros that do not take the API variant into account, such as VK_MAKE_VERSION or VK_VERSION_MAJOR, are superseded by those that do, such as VK_MAKE_API_VERSION or VK_API_VERSION_MAJOR.

Instead of VK_API_VERSION, specific version defines (e.g. VK_API_VERSION_1_0) or the VK_MAKE_API_VERSION macro should be used instead.


### Device Layers: Superseded via instance layers

Previous versions of this specification distinguished between instance and device layers. Instance layers were only able to intercept commands that operate on VkInstance and VkPhysicalDevice, except they were not able to intercept vkCreateDevice. Device layers were enabled for individual devices when they were created, and could only intercept commands operating on that device or its child objects.

Device-only layers are now marked as legacy, and this specification no longer distinguishes between instance and device layers. Layers are enabled during instance creation, and are able to intercept all commands operating on that instance or any of its child objects. At the time this was marked as legacy, there were no known device-only layers and no compelling reason to create one.

The enabledLayerCount parameter of VkDeviceCreateInfo must be zero.


### Render Pass Functions: Superseded via version 2

VK_KHR_create_renderpass2 and Vulkan 1.2 introduced new versions of several render pass functions. These provide the same functionality as the Vulkan 1.0 functionality but with greater extensibility.

Render pass objects and all related commands are further superseded by dynamic rendering.


### Render Pass Objects: Superseded via dynamic rendering

VK_KHR_dynamic_rendering and Vulkan 1.3 added a new way to specify render passes without needing to create VkFramebuffer and VkRenderPass objects. However, subpass functionality had no equivalent, meaning dynamic rendering was only suitable as a substitute for content not using subpasses.

VK_KHR_dynamic_rendering_local_read and Vulkan 1.4 later allowed the expression of most subpass functionality in core or extensions. Any subpass functionality which was not replicated is still expressible but requires applications to split work over multiple dynamic render pass instances. Functionality not covered with local reads would result in most or all vendors splitting the subpass internally.
	

VK_QCOM_render_pass_shader_resolve does not have equivalent functionality exposed via dynamic rendering. Use of legacy functionality will be required to use that extension unless/until replacements are created.

Outside of vendor extensions, applications are advised to make use of vkCmdBeginRendering and vkCmdEndRendering to manage render passes from this API version onward.


### Sampler and Buffer View Objects: Unnecessary with Descriptor Heaps

When using descriptor heaps, the creation of sampler and buffer view objects are wholly unnecessary. Instead, these objects are directly converted to descriptors via vkWriteSamplerDescriptorsEXT and vkWriteResourceDescriptorsEXT, skipping the need to create objects altogether. In the case of samplers, samplers can also be embedded directly into a shader via [shader bindings](https://docs.vulkan.org/spec/latest/chapters/descriptorheaps.html#descriptorheaps-bindings), which only requires the VkSamplerCreateInfo, rather than a created object.

The creation of image views can also be skipped similarly for images used as descriptors, but image views themselves are still used elsewhere in the spec, such as for render passes.


### Descriptor Management: Replaced by descriptor Heaps

[Descriptor heaps](https://docs.vulkan.org/spec/latest/chapters/descriptorheaps.html#descriptorheaps) provide a complete alternative for managing shader resources, and can be used where present instead of the resource management provided by Vulkan 1.0. Descriptor heaps can similarly be used instead of VK_EXT_descriptor_buffer.

While it is possible to use a mix of these in the same application, they cannot be used at the same time, and there are potential performance penalties for switching on some implementations.



### Synchronization Commands: Deprecation via version 2

VK_KHR_synchronization2 was incorporated into Vulkan 1.3, which introduced new versions of synchronization functions. These provide the same functionality as the Vulkan 1.0 functionality but with greater extensibility.

Synchronization 2 commands should be used instead of synchronization 1 commands.

There is one piece of functionality in the original synchronization commands that cannot be mapped easily however. vkCmdSetEvent did not include an access scope; instead the access scope for an event dependency was fully specified by vkCmdWaitEvents. This allowed execution only dependencies to be expressed with cache access management handled at the end of the command. While the same dependencies can be expressed in VK_KHR_synchronization2, it is not a 1:1 mapping, requiring additional commands to be recorded, and so may not be as efficient.

VK_KHR_maintenance9 added the VK_DEPENDENCY_ASYMMETRIC_EVENT_BIT_KHR dependency flag, which enables this use case with vkCmdSetEvent2 and vkCmdWaitEvents2, making it efficient to express the same dependencies.

New flag values added by this extension are additionally extended to 64-bits.



### 32-bit Flags: Extended by 64-bit Flags

Initially Vulkan used 32-bit types to representing sets of flags (Vk*Flags) and individual flag bits (Vk*FlagBits). New functionality added many new flag bits. When the 32-bit types run out of available bits, new 64-bit flags (Vk*Flags2) and flag bits (Vk*FlagBits2) types are introduced.

These new types include all of the flag bits defined by the 32-bit types they correspond to, while allowing up to 32 additional bits. The new types are contained by corresponding extending structures. Such structures are used to specify or query flags by adding them to a pNext chain. When specifying 64-bit flags, those flags are used instead of the 32-bit flags in the base structure being extended. When querying 64-bit flags, both the 64-bit flags in the pNext chain and the 32-bit flags in the in the base structure being extended are returned.

64-bit flag and flag bit types are named the same as the 32-bit types they supersede, but with the addition of a “2” ahead of any vendor suffix. For example, VkPipelineCreateFlagBits and VkPipelineCreateFlags are superseded by VkPipelineCreateFlagBits2 and VkPipelineCreateFlags2, respectively.



### Buffer Commands: Superseded by device address commands

Most commands that previously took buffer objects, including all command buffer commands, have now been superseded by equivalent commands or structures that use [VkDeviceAddressRangeKHR](https://docs.vulkan.org/spec/latest/chapters/fundamentals.html#VkDeviceAddressRangeKHR) structures to specify the address range directly. Some of these need a little additional information from the application in the form of VkAddressCommandFlagBitsKHR, which previously would have been retrieved from the buffer object itself.
