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

#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;

RWTexture2D<float4> gPosW; // xyz: world space position
RWTexture2D<float4> gNormW; // xyz: world space normal vector, w: depth
RWTexture2D<float4> gEmittedLight; // xyz: incoming radiance (y)
RWTexture2D<float4> gDirToSample;  // xyz: direction to light sample, w: distance to the light sample
RWTexture2D<float4> gReservoir; // x: weight, y: sum of weights, z: number of candidates M, w: frame number
RWTexture2D<float4> gDiff; // xyz: sample diffuse BRDF

RWTexture2D<float2> gMotionVector; // xy: 2D screen space motion vector

// Output channels:
RWTexture2D<float4> gReservoirOut;
RWTexture2D<float4> gEmittedLightOut;
RWTexture2D<float4> gDirToSampleOut;
RWTexture2D<float4> gSampleNormalAreaOut;

// Previous frame data:
RWTexture2D<float4> gPosWPrev;
RWTexture2D<float4> gNormWPrev;
RWTexture2D<float4> gEmittedLightPrev;
RWTexture2D<float4> gDirToSamplePrev;
RWTexture2D<float4> gSampleNormalAreaPrev;
RWTexture2D<float4> gReservoirPrev;


cbuffer CB {
	uint width;
	uint height;
	uint frameCount;
}

void updateReservoir(float3 Li, float4 dirToSample, float w, uint2 pixel, uint2 pixelNeighbor, inout SampleGenerator sg, inout bool updated)
{
	gReservoirOut[pixel].y += w;
	gReservoirOut[pixel].z += 1.0f;
	if(gReservoirOut[pixel].y > 0.0f && sampleNext1D(sg) < (w / gReservoirOut[pixel].y))
	{
		updated = true;
		gEmittedLightOut[pixel] = float4(Li, 1.f);
		gDirToSampleOut[pixel] = dirToSample;
	}
}


float evalTargetPDF(float3 brdf, float3 Li, float3 lightDir, float3 surfNormal, float lightDist)
{
	float G = max(dot(lightDir, surfNormal), 0.0f); // Geometry term
	return length(brdf * Li * G);
}

void copyToPrev(uint2 pixel)
{
	gPosWPrev[pixel] = gPosW[pixel];
	gNormWPrev[pixel] = gNormW[pixel];
	gEmittedLightPrev[pixel] = gEmittedLight[pixel];
	gDirToSamplePrev[pixel] = gDirToSample[pixel];
	gReservoirPrev[pixel] = gReservoir[pixel];
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
	
	if(frameCount == 0)
	{
		copyToPrev(pixel);
		return;
	}
	
    SampleGenerator sg = SampleGenerator(pixel, frameCount);
	
	gReservoirOut[pixel] = gReservoir[pixel];
	gEmittedLightOut[pixel] = gEmittedLight[pixel];
	gDirToSampleOut[pixel] = gDirToSample[pixel];

    
	if(gPosW[pixel].w == 0.0f) {
		return; // This pixel is in the background
	}

    // Reproject the pixel position
	uint2 prevPos = pixel - (uint2)gMotionVector[pixel];

    // Out of frame test
	if(prevPos.x < 0 || prevPos.x >= width || prevPos.y < 0 || prevPos.y >= height) 
	{
		copyToPrev(pixel);
		return;
	}
    
    // Skip the reservoir if the weight is 0
    if(gReservoirPrev[prevPos].x == 0)
    {
        gReservoirOut[pixel].z += gReservoir[prevPos].z;
		copyToPrev(pixel);
		return;
	}
	
	// Normal degree test - 25° angle threshold
	if (dot(gNormW[pixel].xyz, gNormW[prevPos].xyz) < 0.906312f)
    {
		copyToPrev(pixel);
		return;
	}
	
	// Depth test - 10% of depth threshold
	if (gNormW[prevPos].w > 1.1f * gNormW[pixel].w || gNormW[prevPos].w < 0.9f * gNormW[pixel].w)
    {
		copyToPrev(pixel);
		return;
	}
	
	float3 lightPosW = gDirToSamplePrev[prevPos].xyz * gDirToSamplePrev[prevPos].w + gPosWPrev[prevPos].xyz;
	float4 newDirToSample = float4(normalize(lightPosW - gPosW[pixel].xyz), length(lightPosW - gPosW[pixel].xyz));
	
	float targedPDF = evalTargetPDF(gDiff[pixel].xyz, gEmittedLightPrev[prevPos].xyz, newDirToSample.xyz, gNormW[pixel].xyz, newDirToSample.w);

	float w = targedPDF * gReservoirPrev[prevPos].x * gReservoirPrev[prevPos].z;
	
	bool updated = false;
	updateReservoir(gEmittedLightPrev[prevPos].xyz, newDirToSample, w, pixel, prevPos, sg, updated);
	
	gReservoirOut[pixel].z += gReservoirPrev[prevPos].z;
	
	if(!updated)
	{
		copyToPrev(pixel);
		return;
	}
	
	if(gReservoirOut[pixel].z == 0 || targedPDF == 0) 
	{
		gReservoirOut[pixel].x = 0.0f;
	}
	else 
	{
		gReservoirOut[pixel].x = gReservoirOut[pixel].y / (gReservoirOut[pixel].z * targedPDF);
	}
	
	copyToPrev(pixel);
}
