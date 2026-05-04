/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * Licensed under the Oculus SDK License Agreement (the "License");
 * you may not use the Oculus SDK except in compliance with the License,
 * which is provided at the time of installation or download, or which
 * otherwise accompanies this software in either electronic or hard copy form.
 *
 * You may obtain a copy of the License at
 *
 * https://developer.oculus.com/licenses/oculussdk/
 *
 * Unless required by applicable law or agreed to in writing, the Oculus SDK
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
For Distant Objects (Beyond 7m):
1. Default to occlusion = 1.0 (visible)
2. Per-pixel check: If valid real-world depth exists = Occlude that pixel
3. Per-pixel check: If no valid real-world depth  = Show virtual object
*/

#ifndef META_DEPTH_ENVIRONMENT_OCCLUSION_INCLUDED
#define META_DEPTH_ENVIRONMENT_OCCLUSION_INCLUDED

uniform float4x4 _EnvironmentDepthReprojectionMatrices[2];
uniform float4 _EnvironmentDepthZBufferParams;

#define SAMPLE_OFFSET_PIXELS 6.0f
#define RELATIVE_ERROR_SCALE 0.015f
#define SOFT_OCCLUSIONS_SCREENSPACE_OFFSET SAMPLE_OFFSET_PIXELS / _EnvironmentDepthTexture_TexelSize.zw

// Constants for distant object handling
#define SENSOR_RANGE_LIMIT 7.0f  // ~7m sensor range limit, change if testing


// This check prevents redefinition when included from EnvironmentOcclusionURP.hlsl
#ifndef SAMPLE_ENVIRONMENT_DEPTH_DEFINED
#define SAMPLE_ENVIRONMENT_DEPTH_DEFINED

// Modify the existing SampleEnvironmentDepth to only get the red channel
float SampleEnvironmentDepth(const float2 reprojectedUV)
{
    // Now explicitly get only the red channel since texture has RG format
    return SAMPLE_TEXTURE2D_X(_EnvironmentDepthTexture, sampler_EnvironmentDepthTexture, reprojectedUV).r;
}

#endif // SAMPLE_ENVIRONMENT_DEPTH_DEFINED

// Add new function to sample both depth and flag
float2 SampleEnvironmentDepthWithFlag(float2 uv)
{
    // Sample both R (depth) and G (no-occlusion flag) channels
    return SAMPLE_TEXTURE2D_X(_EnvironmentDepthTexture, sampler_EnvironmentDepthTexture, uv).rg;
}

float SampleEnvironmentDepthLinear(float2 uv)
{
    const float inputDepthEye = SampleEnvironmentDepth(uv);

    const float inputDepthNdc = inputDepthEye * 2.0 - 1.0;
    const float linearDepth = (1.0f / (inputDepthNdc + _EnvironmentDepthZBufferParams.y)) * _EnvironmentDepthZBufferParams.x;

    return linearDepth;
}

// Check if depth data is valid
bool IsValidDepthData(float2 uv, float linearDepth)
{
    // Check UV bounds
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return false;
    
    // Additional check: sample raw depth to detect invalid values
    float rawDepth = SampleEnvironmentDepth(uv);
    if (rawDepth <= 0.001f || rawDepth >= 0.999f)
        return false;
    
    // CRITICAL: FOR TESTING ONY
    if (linearDepth > SENSOR_RANGE_LIMIT)
        return false;
    
    return true;
}

float CalculateEnvironmentDepthHardOcclusion(float2 depthUv, float sceneDepth)
{
    // First check the no-occlusion flag
    float2 depthAndFlag = SampleEnvironmentDepthWithFlag(depthUv);
    float noOcclusionFlag = depthAndFlag.g;
    
    // If no-occlusion flag is set, always show virtual content
    if (noOcclusionFlag > 0.5f)
    {
        return 1.0f; // No occlusion - always show virtual object
    }
    
    float environmentDepth = SampleEnvironmentDepthLinear(depthUv);
    
    // Check if we have valid depth data
    bool hasValidDepth = IsValidDepthData(depthUv, environmentDepth);
    
    // DISTANT OBJECT LOGIC
    if (sceneDepth > SENSOR_RANGE_LIMIT)
    {
        // For distant objects: only occlude if we have valid real-world depth data
        // that is closer than the virtual object
        if (hasValidDepth && environmentDepth < sceneDepth)
        {
            return 0.0f; // Occlude - real object is closer
        }
        else
        {
            return 1.0f; // Show virtual object (no valid occlusion data or real object is farther)
        }
    }
    else
    {
        // CLOSE OBJECTS LOGIC
        if (!hasValidDepth)
        {
            return 1.0f;
        }
        
        return environmentDepth > sceneDepth ? 1.0f : 0.0f;
    }
}

float CalculateEnvironmentDepthSoftOcclusion(float2 uvCoords, float linearSceneDepth)
{
    // Check for no-occlusion flag first
    float2 depthAndFlag = SampleEnvironmentDepthWithFlag(uvCoords);
    if (depthAndFlag.g > 0.5f)
    {
        return 1.0f; // No occlusion in masked areas
    }
    
    const float2 halfPixelOffset = 0.5f * float2(_PreprocessedEnvironmentDepthTexture_TexelSize.xy);
    uvCoords -= halfPixelOffset;

    float biasedDepthSpace = _EnvironmentDepthZBufferParams.x / linearSceneDepth - _EnvironmentDepthZBufferParams.y;

    float cubeDepthRangeLow = (biasedDepthSpace + 1.0f) * 0.5f;

    const float kRange = 1.0f / 1.04f - 1.0f;
    float cubeDepthRangeInv = 1.0f / (cubeDepthRangeLow * kRange - kRange);

    float4 texSample = SamplePreprocessedDepth(uvCoords, unity_StereoEyeIndex);
    float3 minMaxMid = float3(1.0f - texSample.x, 1.0f - texSample.y, texSample.z + 1.0f - texSample.x);
    float3 alphas = clamp((minMaxMid - cubeDepthRangeLow) * cubeDepthRangeInv, 0.0f, 1.0f);

    float alpha = alphas.z;
    if (alphas.y - alphas.x > 0.03f)
    {
        // Mix the minima and maxima according to the given interpolation factor.
        // Adjust the smoothstep coefficients to shrink or enlarge the transition radius.
        // Between 0.0f (transition deepest in the foreground) and 0.5f (don't transition in the foreground)
        const float kForegroundLevel = 0.2f;
        // Between 0.5f (don't transition in the background) and 1.0f (transition deepest in the background)
        const float kBackgroundLevel = 0.8f;
        float interp = texSample.z / texSample.w;
        alpha = lerp(alphas.x, alphas.y, smoothstep(kForegroundLevel, kBackgroundLevel, interp));
    }

    if (linearSceneDepth > SENSOR_RANGE_LIMIT)
    {
        // For distant objects in soft occlusion, check if we have valid preprocessed data
        if (texSample.w <= 0.001f || any(isnan(texSample)) || any(isinf(texSample)))
        {
            return 1.0f; // Show distant objects when no valid soft occlusion data
        }
    }

    return alpha;
}

float CalculateEnvironmentDepthOcclusion(float3 worldCoords, float bias)
{
    const float4 depthSpace =
    mul(_EnvironmentDepthReprojectionMatrices[unity_StereoEyeIndex], float4(worldCoords, 1.0));

    const float2 uvCoords = (depthSpace.xy / depthSpace.w + 1.0f) * 0.5f;

    float linearSceneDepth = (1.0f / ((depthSpace.z / depthSpace.w) + _EnvironmentDepthZBufferParams.y)) * _EnvironmentDepthZBufferParams.x;
    linearSceneDepth -= bias * linearSceneDepth * UNITY_NEAR_CLIP_VALUE;

#if defined(HARD_OCCLUSION)
   return CalculateEnvironmentDepthHardOcclusion(uvCoords, linearSceneDepth);
#elif defined(SOFT_OCCLUSION)
   return CalculateEnvironmentDepthSoftOcclusion(uvCoords, linearSceneDepth);
#endif

    return 1.0f;
}

#if defined(HARD_OCCLUSION) || defined(SOFT_OCCLUSION)

#define META_DEPTH_VERTEX_OUTPUT(number) \
  float3 posWorld : TEXCOORD##number;

#define META_DEPTH_INITIALIZE_VERTEX_OUTPUT(output, vertex) \
  output.posWorld = META_DEPTH_CONVERT_OBJECT_TO_WORLD(vertex)

#define META_DEPTH_GET_OCCLUSION_VALUE_WORLDPOS(posWorld, zBias) \
  CalculateEnvironmentDepthOcclusion(posWorld.xyz, zBias);

#define META_DEPTH_GET_OCCLUSION_VALUE(input, zBias) META_DEPTH_GET_OCCLUSION_VALUE_WORLDPOS(input.posWorld, zBias);

#define META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY_WORLDPOS(posWorld, output, zBias) \
    float occlusionValue = META_DEPTH_GET_OCCLUSION_VALUE_WORLDPOS(posWorld, zBias); \
    output *= occlusionValue; \

#define META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY_WORLDPOS_NAME(input, fieldName, output, zBias) \
  META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY_WORLDPOS(input . ##fieldName, output, zBias)

#define META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY(input, output, zBias) \
  META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY_WORLDPOS(input.posWorld, output, zBias)

#else

#define META_DEPTH_VERTEX_OUTPUT(number)
#define META_DEPTH_INITIALIZE_VERTEX_OUTPUT(output, vertex)
#define META_DEPTH_GET_OCCLUSION_VALUE_WORLDPOS(posWorld, zBias) 1.0
#define META_DEPTH_GET_OCCLUSION_VALUE(input, zBias) 1.0
#define META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY_WORLDPOS(posWorld, output, zBias)
#define META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY_WORLDPOS_NAME(input, fieldName, output, zBias)
#define META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY(input, output, zBias) output = output

#endif

#endif
