/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/

#include "Scene/SceneDefines.slangh"

import Scene.Raytracing;
import Scene.Intersection;

/** Payload for shadow ray.
*/
struct ShadowRayData
{
    bool visible;
};

// Inputs
RWTexture2D<float4> gPosW;                  // G-buffer world-space position

// Input/Outputs
// GBufferRT RIS channels
RWTexture2D<float4> gDirToSample;  // xyz: direction to light sample, w: distance to the light sample
RWTexture2D<float4> gSampleNormalArea; // xyz: sample normal, w: area of the light
RWTexture2D<float4> gReservoir; // x: weight, y: sum of weights, z: number of candidates M, w: frame number


/** Traces a shadow ray towards a light source.
    \param[in] origin Ray origin for the shadow ray.
    \param[in] dir Direction from shading point towards the light source (normalized).
    \param[in] distance Distance to the light source.
    \return True if light is visible, false otherwise.
*/
bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.00001f;
    ray.TMax = distance;

    ShadowRayData rayData;
    rayData.visible = false;    // Set to true by miss shader if ray is not terminated before
    TraceRay(gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

    return rayData.visible;
}



[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    // The miss shader is executed if the ray misses all geometry. Mark as visible.
    rayData.visible = true;
}


// [shader("anyhit")]
// void shadowTriangleMeshAnyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
// {
    // // Alpha test for non-opaque geometry.
    // GeometryInstanceID instanceID = getGeometryInstanceID();
    // VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    // const uint materialID = gScene.getMaterialID(instanceID);
    // if (gScene.materials.alphaTest(v, materialID, 0.f)) IgnoreHit();
// }

//
// Shader entry point for ray generation shader.
//

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
	float4 reservoir = gReservoir[pixel];
	if(gPosW[pixel].w != 0.0f) 
	{
		// if(!traceShadowRay(gPosW[pixel].xyz, gDirToSample[pixel].xyz, gDirToSample[pixel].w))
		if(!traceShadowRay(gPosW[pixel].xyz, gDirToSample[pixel].xyz, gDirToSample[pixel].w))
		{
			reservoir.x = 0.0f;
		}
	}
	gReservoir[pixel] = reservoir;
}
