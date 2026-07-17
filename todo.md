# To Do
- do a depth prepass where we only render into the depthbuffer
  - then do a second pass, where depthtest is set to Equal, in which we compute the color

- [meshlet compression](https://youtu.be/VXN4Gewjk4k?t=147)
- [texel fetch in final_comp](https://youtu.be/VXN4Gewjk4k?t=11467)
- [texel fetch in shadowblur shadowfill](https://youtu.be/VXN4Gewjk4k?t=12347)

- [Avoid writing past the end of task command buffer](https://github.com/zeux/niagara/commit/43d70544af50d924e902cc7bb5e18ccda35d6271)
- [Adjust settings for better performance on RDNA3](https://github.com/zeux/niagara/commit/86749713f4da3ab39b06546b1592fe005a5d2f3b)

- [Switch to automatic LOD selection](https://github.com/zeux/niagara/commit/e9e0521f41be965ff7595ec4339bd532619ba561)
- [Use normals for LODs and steeper triangle count curve](https://github.com/zeux/niagara/commit/d7bcdbb59e53c5bdeda97c419f81e69081d09aa5)
- [Take into account mesh dimensions when saving LOD errors](https://github.com/zeux/niagara/commit/75d4f5d67f4e069c3c1568d516aee2dcaf919f1a)