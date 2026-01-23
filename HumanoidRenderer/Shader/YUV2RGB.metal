//
//  YUV2RGB.metal
//  HumanoidRenderer
//
//  Created by Voltline on 2026/1/23.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 常量定义
// 双线性过滤采样器，边缘模式为 Clamp to Edge
constexpr sampler bilinearSampler(address::clamp_to_edge, filter::linear);

// BT.709 Limited Range -> Full Range RGB 转换矩阵
constant float3x3 kBT709LimitedToFullMatrix = float3x3(
    float3(1.16438f,  1.16438f,  1.16438f), // Column 0: Y系数
    float3(0.00000f, -0.21324f,  2.11240f), // Column 1: U(Cb)系数
    float3(1.79314f, -0.53315f,  0.00000f)  // Column 2: V(Cr)系数
);

// BT.601 Limited Range -> Full Range RGB 转换矩阵
constant float3x3 kBT601LimitedToFullMatrix = float3x3(
    float3(1.164f,  1.164f,  1.164f),
    float3(0.000f, -0.391f,  2.018f),
    float3(1.596f, -0.813f,  0.000f)
);

// MARK: - 核函数
// nvl2ToRgba: kernel function for yuv->rgba
kernel
void
nvl2ToRgba(
           texture2d<float, access::sample> yTexture [[texture(0)]],
           texture2d<float, access::sample> uvTexture [[texture(1)]],
           texture2d<float, access::write> rgbaTexture [[texture(2)]],
           constant float &yNormalizedOffset [[buffer(0)]],
           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= rgbaTexture.get_width() || gid.y >= rgbaTexture.get_height()) {
        return;
    }
    
    // 计算归一化坐标
    float2 targetUV = float2(gid) / float2(rgbaTexture.get_width(), rgbaTexture.get_height());
    
    // 处理上下两部分的纹理
    float2 sourceUV = float2(targetUV.x, targetUV.y * 0.5f + yNormalizedOffset);
    
    // 采样 YUV 数据
    float y_raw = yTexture.sample(bilinearSampler, sourceUV).r;
    float2 uv_raw = uvTexture.sample(bilinearSampler, sourceUV).rg;
    
    // MARK: - 颜色空间转换
    // 调整 Range 偏移
    float y_adj = y_raw - 0.062745f;    // 16 / 255 ~ 0.0627
    float2 uv_adj = uv_raw - 0.5f;       // 128 / 255 ~ 0.5
    
    // 矩阵乘法
    float3 yuvVec = float3(y_adj, uv_adj.x, uv_adj.y);
    float3 rgb = kBT709LimitedToFullMatrix * yuvVec;
    
    // 进行 Gamma 校正
    rgb = max(rgb, 0.0f); // 避免出现负值
    rgb = pow(rgb, 1.4f);
    
    rgbaTexture.write(float4(rgb, 1.0f), gid);
}
