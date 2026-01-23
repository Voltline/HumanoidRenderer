//
//  YUV2RGB.metal
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/23.
//

#include <metal_stdlib>
using namespace metal;

// nvl2ToRgba: kernel function for yuv->rgba
kernel
void
nvl2ToRgba(
           texture2d<float, access::read> yTexture [[texture(0)]],
           texture2d<float, access::read> uvTexture [[texture(1)]],
           texture2d<float, access::write> rgbaTexture [[texture(2)]],
           constant uint &y_offset [[buffer(0)]],
           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= rgbaTexture.get_width() || gid.y >= rgbaTexture.get_height()) {
        return;
    }
    
    uint2 read_gid = uint2(gid.x, gid.y + y_offset);
    
    // MARK: - YUV to RGBA
    // [R]   [1   0         1.5748][ Y  ]
    // [G] = [1  -0.1873   -0.4681][ Cb ]
    // [B]   [1   1.8556    0     ][ Cr ]
    // Cb = U - 0.5, Cr = V - 0.5
    
    // Y 纹理读取
    float y = yTexture.read(read_gid).r;
    
    // UV 纹理采样坐标
    uint2 uv_read_gid = uint2(read_gid.x / 2, read_gid.y / 2);
    float2 uv = uvTexture.read(uv_read_gid).rg;
    
    // Limited Range -> Full Range
    float cb = uv.x - 0.5;
    float cr = uv.y - 0.5;

    
    // YUV -> RGBA
    float r = y + 1.5748 * cr;
    float g = y - 0.1873 * cb - 0.4681 * cr;
    float b = y + 1.8556 * cb;
    
    rgbaTexture.write(float4(r, g, b, 1.0), gid);
}
