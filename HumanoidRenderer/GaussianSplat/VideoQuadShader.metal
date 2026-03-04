//
//  VideoQuadShader.metal
//  HumanoidRenderer
//
//  Created by Voltline on 2026/3/4.
//
//  简单的纹理四边形着色器，用于在 CompositorServices 渲染管线中
//  绘制前景视频平面。
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 顶点数据结构
struct VideoQuadVertex {
    float4 position [[position]];
    float2 texCoord;
    uint   renderTargetArrayIndex [[render_target_array_index]];
};

struct VideoQuadUniforms {
    float4x4 modelViewProjection[2]; // 支持两只眼睛
};

// MARK: - 全屏四边形顶点
// 使用 amplification_id 为双眼渲染
vertex VideoQuadVertex videoQuadVertexShader(
    uint vertexID [[vertex_id]],
    uint ampID [[amplification_id]],
    constant VideoQuadUniforms &uniforms [[buffer(0)]]
) {
    // 经典全屏三角形/四边形 (两个三角形, 6 个顶点)
    // 顶点顺序: 左下, 右下, 左上, 右下, 右上, 左上
    constexpr float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2( 1, -1), float2( 1,  1), float2(-1,  1)
    };
    constexpr float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(1, 1), float2(1, 0), float2(0, 0)
    };
    
    // 在 3D 空间中放置一个平面 (宽 1.778, 高 1.0, 距离 -2m)
    float2 pos2d = positions[vertexID];
    float4 worldPos = float4(pos2d.x * 0.889, pos2d.y * 0.5, -2.0, 1.0);
    
    VideoQuadVertex out;
    out.position = uniforms.modelViewProjection[ampID] * worldPos;
    out.texCoord = texCoords[vertexID];
    out.renderTargetArrayIndex = ampID;
    return out;
}

// MARK: - 片段着色器
fragment float4 videoQuadFragmentShader(
    VideoQuadVertex in [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler bilinear(address::clamp_to_edge, filter::linear);
    return tex.sample(bilinear, in.texCoord);
}
