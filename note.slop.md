With `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER`, the “sampler” is part of the descriptor, so “changing the sampler for an already uploaded texture” means updating the **descriptor entry** (not the texture memory).

Conceptually:

1) Texture image stays the same.
2) Create/choose a new `VkSampler` (or reuse an existing one).
3) Update the descriptor buffer contents for that index `i` so its sampler handle points to the new `VkSampler`.

### Shader-side
No change (still):
```glsl
layout(binding = 1) uniform sampler2D textures_heap[];
vec3 albedo = texture(textures_heap[i], uv).rgb;
```

### CPU-side (descriptor buffer) update
You rewrite only the descriptor bytes for entry `i` in your descriptor buffer, then ensure visibility to the GPU (flush/invalidate + pipeline sync as needed).

Pseudocode outline:
```cpp
uint32_t i = texture_index;

// 1) pick a new VkSampler
VkSampler newSampler = samplers[...];

// 2) update descriptor entry i in the descriptor buffer
//    (imageView stays the same for that texture; only sampler changes)
write_combined_image_sampler_descriptor(
    descriptorBufferMappedPtr + descriptorStride * i,
    imageView_of_texture[i],
    newSampler,
    imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL // or what you use
);

// 3) make it visible to GPU
flush_mapped_range(descriptorBufferMemory, descriptorStride*i, descriptorSize);
```

### Vulkan sync you typically need
- If the descriptor buffer memory is **host-coherent**, flushing may be unnecessary.
- Otherwise, you must `vkFlushMappedMemoryRanges` (or your platform equivalent).
- Then you generally use a barrier/synchronization so the draw/dispatch reads the updated descriptors (e.g., `vkCmdPipelineBarrier2` or equivalent sync depending on your descriptor-buffer usage pattern).

If you share:
- whether you’re using **descriptor buffers** (`VK_EXT_descriptor_buffer`) and the exact descriptor write struct you use (e.g. `VkDescriptorGetInfoEXT` + `vkGetDescriptorEXT`), and
- the descriptor format/stride you’re writing,
I can give the exact function/struct-level code for updating entry `i` in-place.