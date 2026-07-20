# To Do
- do a depth prepass where we only render into the depthbuffer
  - then do a second pass, where depthtest is set to Equal, in which we compute the color

- [meshlet compression](https://youtu.be/VXN4Gewjk4k?t=147)
- [texel fetch in final_comp](https://youtu.be/VXN4Gewjk4k?t=11467)
- [texel fetch in shadowblur shadowfill](https://youtu.be/VXN4Gewjk4k?t=12347)

- [Switch to automatic LOD selection](https://github.com/zeux/niagara/commit/e9e0521f41be965ff7595ec4339bd532619ba561)
- [Use normals for LODs and steeper triangle count curve](https://github.com/zeux/niagara/commit/d7bcdbb59e53c5bdeda97c419f81e69081d09aa5)
- [Take into account mesh dimensions when saving LOD errors](https://github.com/zeux/niagara/commit/75d4f5d67f4e069c3c1568d516aee2dcaf919f1a)

- [Faster scene loading option](https://github.com/zeux/niagara/commit/1391590b37784586ec0118595ab2316b88edfa01)
- [Improve LOD generation](https://github.com/zeux/niagara/commit/7599cd4191b556754f2f24a49345fe593c6e96b8)
- [Add debug settings for LOD](https://github.com/zeux/niagara/commit/9d143495f521d1f95c32ba2a7706673b2b6a1de4)